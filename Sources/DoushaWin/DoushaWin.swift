// Dousha Windows shell (QUA-209): tray icon + hold-to-talk hotkey + waveIn
// capture + SendInput injection around the cross-platform DoubaoASR engine.
//
// One cohesive file on purpose (QUA-207 taste): config, recorder
// orchestration, Win32 plumbing, and the --doctor self-test all read top to
// bottom here; only the genuinely self-contained device code (WaveInCapture,
// TextInjector) lives next door.
//
// Threading model — two long-lived threads:
//   main thread:  dispatchMain(). The engine delivers partials / finals /
//                 errors via DispatchQueue.main; without a drained main queue
//                 every completion would silently vanish (there is no NSApp
//                 runloop here).
//   UI thread:    hidden window + tray icon + WH_KEYBOARD_LL hook + the
//                 GetMessage loop. Hooks fire on the thread that installed
//                 them, so hotkey events arrive here and only ever spawn a
//                 Task — the LL-hook callback must return in milliseconds or
//                 Windows silently removes the hook.
//
// v1 scope (deliberate): no HUD (partials go to dousha.log), no settings UI
// (config.json next to credentials.json), Doubao only, console subsystem so
// launching from a terminal shows logs.
#if os(Windows)
import WinSDK
import Foundation
import Dispatch
import DoubaoASR
import ASRSupport
import TalkerCommonSync

// MARK: - Config

struct WinConfig: Codable {
    /// Hold-to-talk key. Hold to record, release to inject.
    var hotkey: String = "rightctrl"
    /// Swallow the hotkey so the focused app never sees it (a held Ctrl
    /// would otherwise trigger shortcuts mid-dictation).
    var swallowHotkey: Bool = true

    static let vkMap: [String: UInt32] = [
        "rightctrl": 0xA3, "leftctrl": 0xA2,
        "rightshift": 0xA1, "leftshift": 0xA0,
        "rightalt": 0xA5, "leftalt": 0xA4,
        "capslock": 0x14,
        "f8": 0x77, "f9": 0x78, "f10": 0x79,
        "scrolllock": 0x91, "pause": 0x13,
    ]

    var vkCode: UInt32 { Self.vkMap[hotkey.lowercased()] ?? 0xA3 }

    /// `%LOCALAPPDATA%\Dousha\config.json` — same directory the credential
    /// store already uses. Missing file → defaults are written out so the
    /// user has something to edit.
    static func load() -> WinConfig {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = support.appendingPathComponent("Dousha", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(WinConfig.self, from: data) {
            doushaLog("[DoushaWin] config loaded: hotkey=\(cfg.hotkey) swallow=\(cfg.swallowHotkey)")
            return cfg
        }
        let cfg = WinConfig()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? (try? enc.encode(cfg))?.write(to: url)
        doushaLog("[DoushaWin] wrote default config to \(url.path)")
        return cfg
    }
}

// MARK: - Recorder orchestration

/// Owns one DoubaoASR engine + the mic capture, serialised as an actor so a
/// jittery hotkey can't interleave start/stop. Mirrors the Mac three-phase
/// start order (ARCHITECTURE.md): prepareSession → capture live → openStream
/// (early audio buffers inside the engine until the WS is ready), and the
/// stop order: drain capture first, THEN finish the engine.
actor Recorder {
    private let engine = DoubaoASR()
    private var capture: WaveInCapture?
    private var counter: ByteCounter?
    private var recording = false

    func start() async {
        guard !recording else { return }
        recording = true
        Tray.setRecording(true)
        HUD.update(recording: true, text: "正在听…")
        await engine.prepareSession(
            onPartial: { p in
                doushaLog("[DoushaWin] partial: \(p.combined)")
                HUD.update(recording: true, text: p.combined)
            },
            onError: { e in doushaLog("[DoushaWin] engine error: \(e.localizedDescription)") }
        )
        // Per-session level meter: a muted/wrong mic shows up in the log as
        // peak≈1 instead of a mystery empty transcript (QUA-209 field debug).
        let meter = ByteCounter()
        counter = meter
        let cap = WaveInCapture { [engine] pcm in
            meter.add(pcm)
            engine.ingest(pcm)
        }
        do {
            try cap.start()
        } catch {
            doushaLog("[DoushaWin] capture start failed: \(error.localizedDescription)")
            engine.cancel()
            recording = false
            Tray.setRecording(false)
            HUD.update(recording: false, text: "麦克风启动失败")
            HUD.dismiss(afterMs: 1800)
            return
        }
        capture = cap
        engine.openStream()
    }

    func stop() async {
        guard recording else { return }
        recording = false
        capture?.stop()   // synchronous drain — tail reaches the engine first
        capture = nil
        let nearSilence = (counter?.peak ?? 0) < 500
        if let meter = counter {
            doushaLog("[DoushaWin] mic session: \(meter.bytes) bytes, peak=\(meter.peak)\(nearSilence ? " ⚠️ near-silence" : "")")
        }
        counter = nil
        engine.stop { result in
            doushaLog("[DoushaWin] final: \(result.text)")
            TextInjector.type(result.text)
            Tray.setRecording(false)
            if result.text.isEmpty {
                HUD.update(recording: false,
                           text: nearSilence ? "没听到声音——检查默认麦克风？" : "（没有识别到内容）")
            } else {
                HUD.update(recording: false, text: result.text)
            }
            HUD.dismiss(afterMs: 1400)
        }
    }
}

// MARK: - Globals shared with C callbacks
// Window procs and LL-hook procs are C function pointers — no captures — so
// the shell state they need lives here. All of it is either set once before
// the UI thread starts (gConfig, gRecorder) or touched only on the UI thread
// (gHwnd, gKeyIsDown, the tray data).

nonisolated(unsafe) var gConfig = WinConfig()
nonisolated(unsafe) var gRecorder: Recorder?
nonisolated(unsafe) var gHwnd: HWND?
nonisolated(unsafe) var gKeyIsDown = false   // UI (hook) thread only — dedups autorepeat

let WMAPP_TRAY: UINT = 0x8000 + 1       // WM_APP + 1: tray icon callback
let WMAPP_RECORDING: UINT = 0x8000 + 2  // WM_APP + 2: wParam 1/0 = tooltip swap
let MENU_QUIT: UINT_PTR = 1

// MARK: - Tray icon

enum Tray {
    nonisolated(unsafe) static var nid = NOTIFYICONDATAW()

    static func add(hwnd: HWND) {
        nid.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        nid.hWnd = hwnd
        nid.uID = 1
        nid.uFlags = UINT(NIF_MESSAGE | NIF_ICON | NIF_TIP)
        nid.uCallbackMessage = WMAPP_TRAY
        nid.hIcon = LoadIconW(nil, UnsafePointer<WCHAR>(bitPattern: 32512)) // IDI_APPLICATION
        setTip("Dousha — 按住 \(gConfig.hotkey) 说话")
        Shell_NotifyIconW(DWORD(NIM_ADD), &nid)
    }

    static func remove() {
        Shell_NotifyIconW(DWORD(NIM_DELETE), &nid)
    }

    /// Thread-safe: posts to the UI thread; the wndProc does the NIM_MODIFY.
    static func setRecording(_ on: Bool) {
        if let hwnd = gHwnd {
            PostMessageW(hwnd, WMAPP_RECORDING, WPARAM(on ? 1 : 0), 0)
        }
    }

    /// UI thread only.
    static func applyRecordingTip(_ on: Bool) {
        setTip(on ? "Dousha — 录音中…" : "Dousha — 按住 \(gConfig.hotkey) 说话")
        Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)
    }

    private static func setTip(_ text: String) {
        withUnsafeMutableBytes(of: &nid.szTip) { raw in
            let buf = raw.bindMemory(to: WCHAR.self)
            for i in 0..<buf.count { buf[i] = 0 }
            for (i, u) in text.utf16.prefix(buf.count - 1).enumerated() { buf[i] = u }
        }
    }

    static func showMenu(hwnd: HWND) {
        guard let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }
        "退出 Dousha".withCString(encodedAs: UTF16.self) { label in
            _ = AppendMenuW(menu, UINT(MF_STRING), MENU_QUIT, label)
        }
        var pt = POINT()
        GetCursorPos(&pt)
        SetForegroundWindow(hwnd)   // required or the menu won't dismiss on outside click
        // No TPM_RETURNCMD: TrackPopupMenu's return is a WindowsBool in the
        // Swift overlay, which can't carry the command id — the selection
        // arrives as WM_COMMAND in the wndProc instead.
        TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), pt.x, pt.y, 0, hwnd, nil)
    }
}

// MARK: - Window proc + keyboard hook (C function pointers)

let wndProc: WNDPROC = { hwnd, msg, wParam, lParam in
    switch msg {
    case WMAPP_TRAY:
        // lParam carries the mouse event for the tray icon.
        if lParam == LPARAM(WM_RBUTTONUP) || lParam == LPARAM(WM_CONTEXTMENU) {
            if let hwnd { Tray.showMenu(hwnd: hwnd) }
        }
        return 0
    case WMAPP_RECORDING:
        Tray.applyRecordingTip(wParam == 1)
        return 0
    case UINT(WM_COMMAND):
        if UINT_PTR(wParam & 0xFFFF) == MENU_QUIT {
            PostQuitMessage(0)
        }
        return 0
    case UINT(WM_DESTROY):
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}

let keyboardHook: HOOKPROC = { code, wParam, lParam in
    if code == HC_ACTION,
       let kb = UnsafePointer<KBDLLHOOKSTRUCT>(bitPattern: Int(lParam)) {
        let vk = kb.pointee.vkCode
        if vk == gConfig.vkCode {
            let isDown = wParam == WPARAM(WM_KEYDOWN) || wParam == WPARAM(WM_SYSKEYDOWN)
            let isUp = wParam == WPARAM(WM_KEYUP) || wParam == WPARAM(WM_SYSKEYUP)
            if isDown && !gKeyIsDown {            // first down only; autorepeat redelivers downs
                gKeyIsDown = true
                if let r = gRecorder { Task { await r.start() } }
            } else if isUp && gKeyIsDown {
                gKeyIsDown = false
                if let r = gRecorder { Task { await r.stop() } }
            }
            if gConfig.swallowHotkey { return 1 } // focused app never sees the PTT key
        }
    }
    return CallNextHookEx(nil, code, wParam, lParam)
}

// MARK: - UI thread

func uiThreadMain() {
    let hInstance = GetModuleHandleW(nil)

    var wc = WNDCLASSW()
    wc.lpfnWndProc = wndProc
    wc.hInstance = hInstance
    let hwnd: HWND? = "DoushaWinShell".withCString(encodedAs: UTF16.self) { className -> HWND? in
        wc.lpszClassName = className
        guard RegisterClassW(&wc) != 0 else {
            doushaLog("[DoushaWin] RegisterClass failed (\(GetLastError()))")
            return nil
        }
        // Hidden top-level window: never shown, exists to receive tray
        // callbacks + our cross-thread WMAPP_RECORDING posts.
        return CreateWindowExW(0, className, className, 0, 0, 0, 0, 0, nil, nil, hInstance, nil)
    }
    guard let hwnd else {
        doushaLog("[DoushaWin] CreateWindow failed (\(GetLastError()))")
        exit(1)
    }
    gHwnd = hwnd

    Tray.add(hwnd: hwnd)
    HUD.create(hInstance: hInstance)
    let hook = SetWindowsHookExW(WH_KEYBOARD_LL, keyboardHook, hInstance, 0)
    if hook == nil {
        doushaLog("[DoushaWin] SetWindowsHookEx failed (\(GetLastError())) — no hotkey!")
    }
    doushaLog("[DoushaWin] shell up: hotkey=\(gConfig.hotkey) (hold to talk)")
    print("Dousha 已启动:按住 \(gConfig.hotkey) 说话,松开后文字会输入到当前焦点窗口。托盘图标右键退出。")

    var msg = MSG()
    // GetMessage's BOOL imports as Bool; -1 (error) is truthy, so a
    // persistent error would spin — acceptable for a hidden window whose only
    // failure mode is process teardown.
    while GetMessageW(&msg, nil, 0, 0) {
        TranslateMessage(&msg)
        DispatchMessageW(&msg)
    }

    if let hook { UnhookWindowsHookEx(hook) }
    Tray.remove()
    doushaLog("[DoushaWin] shell exiting")
    exit(0)
}

// MARK: - Doctor

/// `dousha-win --doctor`: staged self-test printing to the console —
/// network probe, then a real 5-second mic recording through the full
/// engine path. Run it in an interactive session (audio devices and
/// SendInput are not available over a bare SSH service session).
///
/// `--doctor --wav file.wav` replaces the mic with a 16kHz mono s16le WAV
/// streamed through the SAME live engine (the actor, not the smoke
/// transcriber) — proves the engine path end-to-end on a machine with no
/// microphone, e.g. over SSH.
enum Doctor {
    static func run(wavPath: String?) async -> Int32 {
        print("== dousha-win --doctor ==")
        print("log file: %LOCALAPPDATA%\\Dousha\\Logs\\dousha.log")

        print("[1/2] Doubao connectivity probe")
        let probe = await DoubaoConnectivityProbe.run { print("  \($0)") }
        guard probe.success else {
            print("PROBE FAILED — fix network/credentials before the mic test")
            return 1
        }

        let engine = DoubaoASR()
        await engine.prepareSession(
            onPartial: { p in print("  partial: \(p.combined)") },
            onError: { e in print("  engine error: \(e.localizedDescription)") }
        )

        if let wavPath {
            print("[2/2] wav file → live engine (\(wavPath))")
            let pcm: Data
            do {
                pcm = try WavReader.readPCM(path: wavPath)
            } catch {
                print("  wav FAILED — \(error.localizedDescription)")
                engine.cancel()
                return 1
            }
            engine.openStream()
            // Stream in 100ms chunks at real-time — same shape as holding the
            // hotkey. (Faster pacing races stop() against the ~1.5s WS
            // handshake; the engine's startup-grace flush recovers, but the
            // doctor should exercise the normal path, not the rescue path.)
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + 3200, pcm.count)
                engine.ingest(pcm.subdata(in: offset..<end))
                offset = end
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            print("  wav: streamed \(pcm.count) bytes through live engine")
        } else {
            print("[2/2] live mic → Doubao (recording 5s — speak now!)")
            let counter = ByteCounter()
            let cap = WaveInCapture { [engine] pcm in
                counter.add(pcm)
                engine.ingest(pcm)
            }
            do {
                try cap.start()
            } catch {
                print("  mic FAILED — \(error.localizedDescription)")
                engine.cancel()
                return 1
            }
            engine.openStream()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            cap.stop()
            print("  mic: \(counter.bytes) bytes captured, peak=\(counter.peak)\(counter.peak < 500 ? "  ⚠️ near-silence — wrong input device?" : "")")
        }

        let text = await withCheckedContinuation { cont in
            engine.stop { result in cont.resume(returning: result.text) }
        }
        print("  transcript: \(text.isEmpty ? "(empty)" : text)")
        print(text.isEmpty ? "DOCTOR FAILED" : "DOCTOR PASSED")
        return text.isEmpty ? 1 : 0
    }
}

/// Doctor-only tap on the capture stream: byte count + peak |sample| so a
/// muted/wrong mic shows up as numbers, not a mystery empty transcript.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes = 0
    private var _peak: Int = 0
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return _bytes }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return _peak }
    func add(_ data: Data) {
        var localPeak = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for s in raw.bindMemory(to: Int16.self) {
                localPeak = max(localPeak, abs(Int(s)))
            }
        }
        lock.lock()
        _bytes += data.count
        _peak = max(_peak, localPeak)
        lock.unlock()
    }
}

// MARK: - Entry

@main
struct DoushaWin {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--doctor") {
            var wavPath: String?
            if let i = args.firstIndex(of: "--wav"), i + 1 < args.count {
                wavPath = args[i + 1]
            }
            Task {
                let code = await Doctor.run(wavPath: wavPath)
                exit(code)
            }
            dispatchMain()
        }

        // Single instance. Multiple copies each install a keyboard hook and
        // race the credential store across processes — a quadruple double-
        // click registered four Doubao devices in 3ms and the surviving
        // device was rejected server-side (50700000). The mutex is leaked on
        // purpose: it must live as long as the process.
        let mutex = "Dousha.SingleInstance".withCString(encodedAs: UTF16.self) {
            CreateMutexW(nil, true, $0)
        }
        if mutex == nil || GetLastError() == DWORD(ERROR_ALREADY_EXISTS) {
            print("Dousha 已经在运行（看右下角托盘图标）。")
            "Dousha 已经在运行——看右下角托盘图标。".withCString(encodedAs: UTF16.self) { body in
                "Dousha".withCString(encodedAs: UTF16.self) { title in
                    _ = MessageBoxW(nil, body, title, UINT(MB_OK | MB_ICONINFORMATION))
                }
            }
            exit(0)
        }

        gConfig = WinConfig.load()
        gRecorder = Recorder()
        DoubaoCredentialStore.shared.warmup()   // first PTT shouldn't pay registration latency

        let ui = Thread { uiThreadMain() }
        ui.name = "dousha.ui"
        ui.start()

        // Drain DispatchQueue.main forever — engine callbacks land here.
        dispatchMain()
    }
}
#endif
