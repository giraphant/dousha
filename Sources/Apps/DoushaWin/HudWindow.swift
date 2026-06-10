// Floating transcript HUD for the Windows shell (QUA-209).
//
// A borderless, always-on-top, click-through-less but NEVER-activated pill at
// the bottom-center of the work area: red dot + live partials while the
// hotkey is held, the final text for a beat after release, then gone. The
// Windows analogue of the Mac app's FloatingWindow, minus the waveform.
//
// Threading: state lives behind a lock and is written from wherever the
// engine calls back (DispatchQueue.main / the Recorder actor); the window is
// created on the UI thread and repainted there via PostMessage — the same
// post-don't-touch pattern Tray.setRecording uses. WS_EX_NOACTIVATE is
// load-bearing: the HUD must never steal focus from the window receiving the
// injected text.
#if os(Windows)
import WinSDK
import Foundation
import ConcurrencySupport

// ((HWND)-1) — the macro form doesn't import into Swift. A constant
// sentinel, not real shared state.
private nonisolated(unsafe) let HWND_TOPMOST = HWND(bitPattern: -1)

enum HUD {
    // Window-private messages (own window class, so ids only need to be
    // unique within this wndProc).
    static let MSG_REFRESH: UINT = 0x8000 + 0x10  // repaint with current state
    static let MSG_DISMISS: UINT = 0x8000 + 0x11  // wParam = delay ms, then hide
    private static let TIMER_HIDE: UINT_PTR = 1

    private static let width: Int32 = 600
    private static let height: Int32 = 52

    nonisolated(unsafe) static var hwnd: HWND?

    // State (any thread → lock; painted on the UI thread).
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _text = ""
    nonisolated(unsafe) private static var _recording = false

    // MARK: - API (any thread)

    static func update(recording: Bool, text: String) {
        lock.lock()
        _text = text
        _recording = recording
        lock.unlock()
        if let hwnd { PostMessageW(hwnd, MSG_REFRESH, 0, 0) }
    }

    static func dismiss(afterMs ms: UInt32) {
        if let hwnd { PostMessageW(hwnd, MSG_DISMISS, WPARAM(ms), 0) }
    }

    static func snapshot() -> (recording: Bool, text: String) {
        lock.lock()
        defer { lock.unlock() }
        return (_recording, _text)
    }

    // MARK: - UI thread

    static func create(hInstance: HMODULE?) {
        var wc = WNDCLASSW()
        wc.lpfnWndProc = hudProc
        wc.hInstance = hInstance
        wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512)) // IDC_ARROW
        let created: HWND? = "DoushaHUD".withCString(encodedAs: UTF16.self) { className -> HWND? in
            wc.lpszClassName = className
            guard RegisterClassW(&wc) != 0 else { return nil }
            return CreateWindowExW(
                DWORD(WS_EX_TOPMOST) | DWORD(WS_EX_TOOLWINDOW) | DWORD(WS_EX_NOACTIVATE) | DWORD(WS_EX_LAYERED),
                className, className, DWORD(WS_POPUP),
                0, 0, width, height, nil, nil, hInstance, nil)
        }
        guard let created else {
            doushaLog("[HUD] create failed (\(GetLastError())) — shell runs without HUD")
            return
        }
        SetLayeredWindowAttributes(created, 0, 235, DWORD(LWA_ALPHA))
        // Pill shape. The region is owned by the window after SetWindowRgn.
        if let rgn = CreateRoundRectRgn(0, 0, width, height, height, height) {
            SetWindowRgn(created, rgn, false)
        }
        hwnd = created
    }

    /// Bottom-center of the primary work area (above the taskbar).
    private static func position(_ hwnd: HWND) {
        var area = RECT()
        SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &area, 0)
        let x = area.left + ((area.right - area.left) - width) / 2
        let y = area.bottom - height - 28
        SetWindowPos(hwnd, HWND_TOPMOST, x, y, width, height,
                     UINT(SWP_NOACTIVATE) | UINT(SWP_SHOWWINDOW))
    }

    fileprivate static func paint(_ hwnd: HWND) {
        let (recording, text) = snapshot()
        var ps = PAINTSTRUCT()
        guard let dc = BeginPaint(hwnd, &ps) else { return }
        defer { EndPaint(hwnd, &ps) }

        // Double-buffer: tiny window, but partials repaint ~10×/s and GDI
        // flicker is ugly.
        let mem = CreateCompatibleDC(dc)
        let bmp = CreateCompatibleBitmap(dc, width, height)
        let oldBmp = SelectObject(mem, bmp)
        defer {
            SelectObject(mem, oldBmp)
            DeleteObject(bmp)
            DeleteDC(mem)
        }

        var full = RECT(left: 0, top: 0, right: width, bottom: height)
        let bg = CreateSolidBrush(RGB(30, 30, 34))
        FillRect(mem, &full, bg)
        DeleteObject(bg)

        // Status dot: red while listening, green once the final is in.
        let dotBrush = CreateSolidBrush(recording ? RGB(255, 69, 58) : RGB(48, 209, 88))
        let oldBrush = SelectObject(mem, dotBrush)
        let oldPen = SelectObject(mem, GetStockObject(NULL_PEN))
        let d: Int32 = 12
        let dy = (height - d) / 2
        Ellipse(mem, 22, dy, 22 + d + 1, dy + d + 1)
        SelectObject(mem, oldPen)
        SelectObject(mem, oldBrush)
        DeleteObject(dotBrush)

        let font = "Microsoft YaHei UI".withCString(encodedAs: UTF16.self) {
            CreateFontW(-20, 0, 0, 0, 400, 0, 0, 0,
                        DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS), DWORD(CLIP_DEFAULT_PRECIS),
                        DWORD(CLEARTYPE_QUALITY), DWORD(DWORD(DEFAULT_PITCH) | DWORD(FF_DONTCARE)), $0)
        }
        let oldFont = SelectObject(mem, font)
        SetBkMode(mem, TRANSPARENT)
        SetTextColor(mem, RGB(240, 240, 245))

        var textRect = RECT(left: 48, top: 0, right: width - 24, bottom: height)
        var units = Array(text.utf16)
        if !units.isEmpty {
            // Newest words matter during dictation: if the line overflows,
            // right-align so the tail stays visible (overflow clips left).
            var size = SIZE()
            GetTextExtentPoint32W(mem, &units, Int32(units.count), &size)
            let overflow = size.cx > (textRect.right - textRect.left)
            DrawTextW(mem, &units, Int32(units.count), &textRect,
                      UINT(DT_SINGLELINE) | UINT(DT_VCENTER) | UINT(DT_NOPREFIX)
                          | (overflow ? UINT(DT_RIGHT) : UINT(DT_LEFT)))
        }
        SelectObject(mem, oldFont)
        DeleteObject(font)

        BitBlt(dc, 0, 0, width, height, mem, 0, 0, SRCCOPY)
    }

    fileprivate static func refresh(_ hwnd: HWND) {
        KillTimer(hwnd, TIMER_HIDE)
        position(hwnd)
        InvalidateRect(hwnd, nil, false)
    }
}

private func RGB(_ r: Int32, _ g: Int32, _ b: Int32) -> COLORREF {
    COLORREF(r) | (COLORREF(g) << 8) | (COLORREF(b) << 16)
}

private let hudProc: WNDPROC = { hwnd, msg, wParam, lParam in
    switch msg {
    case HUD.MSG_REFRESH:
        if let hwnd { HUD.refresh(hwnd) }
        return 0
    case HUD.MSG_DISMISS:
        if let hwnd { SetTimer(hwnd, 1, UINT(wParam), nil) }
        return 0
    case UINT(WM_TIMER):
        if let hwnd {
            KillTimer(hwnd, 1)
            ShowWindow(hwnd, SW_HIDE)
        }
        return 0
    case UINT(WM_PAINT):
        if let hwnd { HUD.paint(hwnd) }
        return 0
    case UINT(WM_ERASEBKGND):
        return 1  // everything is painted in WM_PAINT (double-buffered)
    default:
        return DefWindowProcW(hwnd, msg, wParam, lParam)
    }
}
#endif
