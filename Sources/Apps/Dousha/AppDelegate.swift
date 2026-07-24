import Cocoa
import SwiftUI
import Speech
import AVFoundation
// @preconcurrency: kAXTrustedCheckOptionPrompt is an imported global the SDK
// hasn't audited for Sendable; treat the access as a warning, not an error.
@preconcurrency import ApplicationServices
import ServiceManagement
import DoubaoASR
import SonioxASR
import ASRSupport
import ConcurrencySupport

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var settingsWindow: NSWindow?

    private let injector = TextInjector()
    private let prefs = Preferences.shared
    private let historyStore = RecordingHistoryStore()

    private let hudModel = FloatingHUDModel()
    private var floatingWindow: FloatingWindow?

    private var hotkey: HotkeyMonitor?
    private var cancelKey: CancelKeyMonitor?
    private let focusTracker = AppFocusTracker(selfBundleId: "com.dousha.app")

    private var recording: RecordingController!
    private var hotkeyRetryDelay: TimeInterval = 3
    private var cancelKeyRetryDelay: TimeInterval = 3

    func applicationDidFinishLaunching(_ notification: Notification) {
        doushaLog("[Dousha] HUD layout revision: \(FloatingHUDView.layoutRevision)")
        applyDockIconVisibility()
        installMainMenu()
        menuBar = MenuBarController(
            openSettings: { [weak self] in self?.openSettings() },
            retranscribeLast: { [weak self] in self?.retranscribeLast() },
            canRetranscribeLast: { [weak self] in
                guard let self else { return false }
                return self.recording.canRetranscribe && self.historyStore.newest() != nil
            })
        menuBar.install()
        floatingWindow = FloatingWindow(model: hudModel)
        recording = RecordingController(environment: RecordingEnvironment(
            makeBackend: { [prefs] in MultiEngineBackend.fromPreferences(prefs) },
            makeReplayBackend: { [prefs] url in MultiEngineBackend.forReplay(prefs, wavURL: url) },
            copyToClipboard: { text in
                let pb = NSPasteboard.general
                pb.clearContents(); pb.setString(text, forType: .string)
            },
            saveHistory: { [prefs, historyStore] transcript, error in
                historyStore.save(wavFrom: AudioCapturePaths.sharedWAV, date: Date(),
                                   engine: prefs.activeEngines.map(\.displayName).joined(separator: "+"),
                                   transcript: transcript,
                                   error: error, limit: prefs.historyLimit)
            },
            updateHistory: { [historyStore] id, transcript in
                historyStore.updateTranscript(id: id, transcript: transcript)
            },
            applyStatusToHUD: { [hudModel] status in hudModel.status = status },
            setHUDVisible: { [weak self] visible in
                if visible { self?.floatingWindow?.show() } else { self?.floatingWindow?.hide() }
            },
            setCancelKeyEnabled: { [weak self] enabled in self?.cancelKey?.setEnabled(enabled) },
            forceDispatcherIdle: { [weak self] in self?.hotkey?.forceDispatcherIdle() },
            resetHUDLevels: { [hudModel] in hudModel.resetLevels() },
            resetHUDTranscript: { [hudModel] in hudModel.resetTranscript() },
            updateHUDTranscript: { [hudModel] partial in hudModel.updateTranscript(partial) },
            pushHUDLevel: { [hudModel] level in hudModel.pushLevel(level) },
            setFinalTranscript: { [hudModel] text in hudModel.setFinalTranscript(text) },
            makeCorrector: { [prefs] in
                // QUA-264: snapshot the correction config NOW (recording start),
                // matching the engines' glossary-snapshot rule. Glossary terms
                // lead the casing list so a user's own casing beats a built-in;
                // they only join in when the glossary feature is on, mirroring
                // what the engines were sent.
                let corrector = TranscriptCorrector(
                    isEnabled: prefs.localCorrectionEnabled,
                    replacements: prefs.localCorrectionRules
                        .compactMap(TranscriptCorrector.Replacement.parse),
                    casingTerms: (prefs.glossaryEnabled ? prefs.glossaryTerms : [])
                        + TranscriptCorrector.builtinCasingTerms
                )
                return { text in
                    let corrected = corrector.correct(text)
                    if corrected != text {
                        doushaLog("[Dousha] local correction changed final (len \(text.count) -> \(corrected.count))")
                    }
                    return corrected
                }
            },
            inject: { [injector] text in injector.inject(text) },
            isRefineEnabled: { [prefs] in
                prefs.llmEnabled && TextRefiner(baseURL: prefs.llmBaseURL, apiKey: prefs.llmAPIKey,
                                                model: prefs.llmModel).isConfigured
            },
            refineMode: { [prefs] in prefs.refineMode },
            refineImmediate: { [prefs] text, done in
                let refiner = TextRefiner(baseURL: prefs.llmBaseURL, apiKey: prefs.llmAPIKey,
                                          model: prefs.llmModel)
                Task { let refined = await refiner.refine(text); done(refined) }
            },
            refineLater: { [prefs] text in
                let refiner = TextRefiner(baseURL: prefs.llmBaseURL, apiKey: prefs.llmAPIKey,
                                          model: prefs.llmModel)
                _ = refiner.refineLater(text) { refined in
                    let pb = NSPasteboard.general
                    pb.clearContents(); pb.setString(refined, forType: .string)
                    doushaLog("[Dousha] deferred refine wrote refined text to clipboard (len=\(refined.count))")
                }
            },
            language: { [prefs] in prefs.language },
            now: { Date() },
            scheduleAfter: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { work() }
                }
            }
        ))
        // Wire HUD button actions. Captured weakly to avoid retain cycles via
        // the FloatingHUDModel that this AppDelegate owns transitively.
        hudModel.onFinish = { [weak self] in
            guard let self else { return }
            let m = NSEvent.mouseLocation
            let overHUD = self.floatingWindow?.isCursorOverPanel() ?? true
            doushaLog("[Dousha] HUD onFinish fired — mouse=(\(Int(m.x)),\(Int(m.y))) overHUD=\(overHUD)")
            guard overHUD else { return }   // drop phantom fires (cursor not on the HUD)
            self.recording.stop()
        }
        hudModel.onCancel = { [weak self] in
            guard let self else { return }
            let m = NSEvent.mouseLocation
            let overHUD = self.floatingWindow?.isCursorOverPanel() ?? true
            doushaLog("[Dousha] HUD onCancel fired — mouse=(\(Int(m.x)),\(Int(m.y))) overHUD=\(overHUD)")
            guard overHUD else { return }   // drop phantom fires (cursor not on the HUD)
            self.recording.cancel()
        }
        requestSpeechAndMicPermissions()

        focusTracker.onChange = { [weak self] focus in
            self?.hudModel.focus = focus
        }
        hudModel.focus = focusTracker.current
        focusTracker.start()

        startHotkeyMonitor()
        startCancelKeyMonitor()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotkeyConfigChanged),
            name: .doushaHotkeyConfigChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCancelHotkeyConfigChanged),
            name: .doushaCancelHotkeyConfigChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLLMEnabledChanged),
            name: .doushaLLMEnabledChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineRoutingChanged),
            name: .doushaEngineRoutingChanged,
            object: nil
        )

        if prefs.activeEngines.contains(.doubao) {
            DoubaoCredentialStore.shared.warmup()
        }
    }

    /// If the app is relaunched while already running (Finder/Spotlight), bring
    /// the settings window back. This is the recovery path when the user has
    /// hidden both the Dock and menu-bar icons.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Self.currentOpenApplicationEventWasLoginItemLaunch() {
            doushaLog("[Dousha] suppress Settings window for login-item launch")
            return false
        }

        openSettings()
        return true
    }

    /// macOS marks the initial `kAEOpenApplication` Apple event with this
    /// keyword when the app is launched as a login item. In that path we should
    /// behave like a background menu-bar helper, not as if the user explicitly
    /// reopened the app.
    private static func currentOpenApplicationEventWasLoginItemLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else {
            return false
        }
        return event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
    }

    // MARK: - System toggles (Dock icon / menu-bar icon)

    /// Apply the persisted Dock-icon preference to the activation policy.
    private func applyDockIconVisibility() {
        NSApp.setActivationPolicy(prefs.showDockIcon ? .regular : .accessory)
    }

    /// A menu-bar accessory app (`LSUIElement`) gets no main menu by default, so
    /// standard shortcuts have nothing to route to. That breaks both Edit actions
    /// (⌘X/⌘C/⌘V/⌘A in Settings text fields) and app/window actions (⌘Q / ⌘W).
    /// Installing a small main menu wires those key equivalents into AppKit's
    /// normal target/action dispatch. The menu itself stays hidden while the app is
    /// an accessory; only its shortcuts are live.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "豆沙")
        appItem.submenu = appMenu
        let quit = appMenu.addItem(withTitle: "退出豆沙", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu

        // nil target → AppKit dispatches the action up the responder chain to the
        // focused text field. String selectors avoid the `copy:` / NSObject.copy
        // ambiguity.
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func handleLLMEnabledChanged() {
        // The settings pane already wrote `prefs.llmEnabled`; just refresh the
        // menu so its "润色：开启/关闭" label stays in sync.
        menuBar.rebuildMenu()
    }

    /// Show/hide the Dock icon at runtime and persist the choice.
    private func setDockIconVisible(_ visible: Bool) {
        prefs.showDockIcon = visible
        applyDockIconVisibility()
    }

    /// Show/hide the menu-bar status item at runtime and persist the choice.
    private func setMenuBarIconVisible(_ visible: Bool) {
        prefs.showMenuBarIcon = visible
        menuBar.setIconVisible(visible)
    }

    private func openSettings() {
        if settingsWindow == nil {
            let actions = SettingsActions(
                isLaunchAtLoginEnabled: { SMAppService.mainApp.status == .enabled },
                // `register()` is idempotent — re-registering an already-enabled
                // service is fine and simply refreshes it.
                setLaunchAtLogin: { enabled in
                    if enabled { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                },
                isDockIconVisible: { [weak self] in self?.prefs.showDockIcon ?? false },
                setDockIconVisible: { [weak self] visible in self?.setDockIconVisible(visible) },
                isMenuBarIconVisible: { [weak self] in self?.prefs.showMenuBarIcon ?? true },
                setMenuBarIconVisible: { [weak self] visible in self?.setMenuBarIconVisible(visible) },
                resetDoubaoCredentials: { [weak self] in self?.menuBar.resetDoubaoCredentials() },
                retranscribe: { [weak self] id in self?.retranscribeEntry(id: id) },
                canRetranscribe: { [weak self] in self?.recording.canRetranscribe ?? false }
            )
            settingsWindow = SettingsWindowFactory.create(actions: actions)
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Menu-bar "重新转录上次": replay the newest history entry.
    private func retranscribeLast() {
        guard let entry = historyStore.newest() else { return }
        retranscribeEntry(id: entry.id)
    }

    /// Shared entry point for menu + settings retranscribe. The Caches dir can
    /// be cleaned behind our back — a dead entry is removed (posting the list
    /// refresh) instead of surfacing a repeated error (spec §4).
    private func retranscribeEntry(id: String) {
        let url = historyStore.wavURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            doushaLog("[Dousha] retranscribe: wav missing for id=\(id) — removing entry")
            historyStore.remove(id: id)
            return
        }
        recording.retranscribe(id: id, url: url)
    }

    // MARK: - Permissions

    // nonisolated: TCC delivers these authorization completions on a background
    // queue. If the method were @MainActor, the empty closures would be inferred
    // main-actor-isolated and Swift's executor check would trap when TCC calls
    // them off-main (dispatch_assert_queue_fail). The body touches no actor state.
    nonisolated private func requestSpeechAndMicPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Hotkey

    private func startHotkeyMonitor() {
        doushaLog("[Dousha] AppDelegate.startHotkeyMonitor: keyCode=\(prefs.hotkey.keyCode) mode=\(prefs.hotkey.mode.rawValue)")
        let monitor = HotkeyMonitor(
            config: prefs.hotkey,
            onStart: { [weak self] in self?.recording.start() },
            onStop:  { [weak self] in self?.recording.stop() }
        )
        if !monitor.start() {
            let delay = hotkeyRetryDelay
            // ponytail: capped backoff keeps permission recovery without idle 3s polling.
            hotkeyRetryDelay = min(delay * 2, 60)
            doushaLog("[Dousha] AppDelegate.startHotkeyMonitor: monitor.start() returned false — will retry in \(Int(delay))s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.startHotkeyMonitor() }
            }
            return
        }
        hotkeyRetryDelay = 3
        hotkey = monitor
        doushaLog("[Dousha] AppDelegate.startHotkeyMonitor: monitor installed successfully")
    }

    @objc private func handleHotkeyConfigChanged() {
        hotkey?.stop()
        hotkey = nil
        startHotkeyMonitor()
        menuBar.rebuildMenu()
    }

    @objc private func handleCancelHotkeyConfigChanged() {
        cancelKey?.stop()
        cancelKey = nil
        startCancelKeyMonitor()
    }

    @objc private func handleEngineRoutingChanged() {
        // Routing slots / primary language changed in Settings. Refresh the menu
        // (engine summary, checkmarks, language) and warm Doubao if now active.
        if prefs.activeEngines.contains(.doubao) { DoubaoCredentialStore.shared.warmup() }
        menuBar.rebuildMenu()
    }

    private func startCancelKeyMonitor() {
        let cfg = prefs.cancelHotkey
        guard let kc = cfg.keyCode else {
            doushaLog("[Dousha] cancel hotkey disabled — not installing monitor")
            return
        }
        // The Lock-wrapped flag is the gate: the event-tap thread reads it on
        // every keyDown to decide whether to swallow the event. We could read
        // self.status directly with main-thread sync, but blocking the event
        // tap is a great way to drop other system events.
        let flag = recording.recordingFlag
        let monitor = CancelKeyMonitor(
            keyCode: kc,
            shouldFire: { flag.value() },
            onFire: { [weak self] in self?.recording.cancel() }
        )
        monitor.setEnabled(flag.value())
        if !monitor.start() {
            let delay = cancelKeyRetryDelay
            cancelKeyRetryDelay = min(delay * 2, 60)
            doushaLog("[Dousha] CancelKeyMonitor: start() failed — retrying in \(Int(delay))s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.startCancelKeyMonitor() }
            }
            return
        }
        cancelKeyRetryDelay = 3
        cancelKey = monitor
        doushaLog("[Dousha] CancelKeyMonitor installed for kc=\(kc)")
    }

}
