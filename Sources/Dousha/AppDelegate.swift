import Cocoa
import SwiftUI
import Speech
import AVFoundation
import ApplicationServices
import DoubaoASR
import SonioxASR
import ASRSupport
import TalkerCommonSync

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    private var speech: SpeechBackend = SpeechBackendFactory.make(
        engine: Preferences.shared.engine,
        language: Preferences.shared.language
    )
    private let injector = TextInjector()
    // Settings "test connection" button still uses LLMRefiner (see SettingsWindow).
    // The dictation inject path uses TextRefiner instead (see refineAndInject).
    private let llm = LLMRefiner()
    private let prefs = Preferences.shared
    private let launchAtLogin: LaunchAtLoginManaging = LaunchAtLoginController()

    private let hudModel = FloatingHUDModel()
    private var floatingWindow: FloatingWindow?

    private var hotkey: HotkeyMonitor?
    private var cancelKey: CancelKeyMonitor?
    /// Mirror of `status == .recording` shared with `CancelKeyMonitor` so its
    /// CGEvent-tap thread can decide whether to swallow Esc without bouncing
    /// to main. Updated from `status.didSet` below.
    private let isRecordingFlag = Lock<Bool>(false)
    /// Monotonic counter bumped whenever a session is terminated (canceled,
    /// completed, errored). `handleStop`'s completion captures the value at
    /// stop-time and refuses to run if the counter has since advanced — that
    /// is what makes "user pressed cancel between stop and the inject" safe.
    private var sessionToken: UInt64 = 0
    /// Earliest wall-clock at which the next `handleStart` is allowed to call
    /// into the backend after a cancel. Backend cancel paths are async (the
    /// Doubao actor enqueues `_cancel` via `Task { … }`), so a press-Esc-then-
    /// immediately-press-hotkey sequence can race with the still-running
    /// teardown — `_start` would see `isRunning == true` and silently no-op.
    /// 250ms is wide enough to cover both backends' teardown in local testing.
    private var nextStartAllowedAt: Date?
    private static let cancelTeardownGuard: TimeInterval = 0.25
    private let focusTracker = AppFocusTracker(selfBundleId: "com.dousha.app")
    /// Set when a Soniox API-key change arrives while a session is live, so the
    /// stale-key rebuild can't run immediately. Consumed at the next start so
    /// the next recording always uses a backend built from the current key.
    private var sonioxBackendDirty = false

    private var status: RecordingStatus = .idle {
        didSet {
            // CRITICAL: update the recording-state mirror BEFORE any UI/state
            // side effects. The CancelKeyMonitor's CGEvent-tap thread reads this
            // flag on every keyDown to decide whether to swallow Esc. If we
            // updated `hudModel.status` first and the tap thread polled in
            // between, it would see the stale flag, swallow the Esc, and the
            // queued handleCancel would then reject (status no longer .recording).
            // The user's keypress gets silently eaten.
            isRecordingFlag.setValue(status == .recording)
            hudModel.status = status
            // Whenever the AppDelegate returns to .idle, force the dispatcher
            // to match — otherwise a key press silently rejected during
            // .transcribing leaves dispatcher.isActive=true, and the user
            // then needs 2-3 presses to actually start a new recording.
            if status == .idle && oldValue != .idle {
                hotkey?.forceDispatcherIdle()
            }
            // Only show/hide on visibility transitions, not on every state
            // change — otherwise .recording → .transcribing → .injecting
            // would re-fade the HUD on each step (strobe effect).
            guard oldValue.isVisible != status.isVisible else { return }
            if status.isVisible {
                floatingWindow?.show()
            } else {
                floatingWindow?.hide()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockIconVisibility()
        setupMenuBar()
        floatingWindow = FloatingWindow(model: hudModel)
        // Wire HUD button actions. Captured weakly to avoid retain cycles via
        // the FloatingHUDModel that this AppDelegate owns transitively.
        hudModel.onFinish = { [weak self] in self?.handleStop() }
        hudModel.onCancel = { [weak self] in self?.handleCancel() }
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
            selector: #selector(handleSonioxConfigChanged),
            name: .doushaSonioxConfigChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLLMEnabledChanged),
            name: .doushaLLMEnabledChanged,
            object: nil
        )

        if prefs.engine == .doubao {
            DoubaoCredentialStore.shared.warmup()
        }
    }

    /// If the app is relaunched while already running (Finder/Spotlight), bring
    /// the settings window back. This is the recovery path when the user has
    /// hidden both the Dock and menu-bar icons.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    // MARK: - System toggles (Dock icon / menu-bar icon)

    /// Apply the persisted Dock-icon preference to the activation policy.
    private func applyDockIconVisibility() {
        NSApp.setActivationPolicy(prefs.showDockIcon ? .regular : .accessory)
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            if let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.size = NSSize(width: 20, height: 20)
                img.isTemplate = true
                btn.image = img
            } else {
                btn.image = NSImage(systemSymbolName: "mic.fill",
                                    accessibilityDescription: "Dousha")
                btn.image?.isTemplate = true
            }
        }
        statusItem.isVisible = prefs.showMenuBarIcon
        rebuildMenu()
    }

    /// Builds an SF Symbol image rendered as a template (auto light/dark) at menu size.
    private func menuIcon(_ symbol: String) -> NSImage? {
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        img.isTemplate = true
        return img
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let triggerLabel = HotkeyMonitor.displayName(forKeyCode: prefs.hotkey.keyCode)
        let modeLabel = prefs.hotkey.mode == .pushToTalk ? "长按" : "轻点"
        let header = NSMenuItem(title: "豆沙 · \(modeLabel) \(triggerLabel) 听写",
                                action: nil, keyEquivalent: "")
        header.image = menuIcon("mic.fill")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        // 引擎 — 子菜单，标题右侧带当前选中值
        let engineItem = NSMenuItem(title: "引擎：\(prefs.engine.displayName)",
                                    action: nil, keyEquivalent: "")
        engineItem.image = menuIcon("waveform")
        let engineMenu = NSMenu()
        for e in Engine.allCases {
            let item = NSMenuItem(title: e.displayName,
                                  action: #selector(selectEngine(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = e.rawValue
            if e == prefs.engine { item.state = .on }
            engineMenu.addItem(item)
        }
        engineMenu.addItem(.separator())
        let resetItem = NSMenuItem(title: "重置豆包凭据…",
                                   action: #selector(resetDoubaoCredentials),
                                   keyEquivalent: "")
        resetItem.target = self
        engineMenu.addItem(resetItem)
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        // 语言 — 子菜单，标题右侧带当前选中值
        let langOptions = LanguageMenu.options(for: prefs.engine, selectedLanguage: prefs.language)
        let currentLang = langOptions.first(where: { $0.isSelected })?.title ?? "自动"
        let langItem = NSMenuItem(title: "语言：\(currentLang)", action: nil, keyEquivalent: "")
        langItem.image = menuIcon("globe")
        let langMenu = NSMenu()
        for option in langOptions {
            let item = NSMenuItem(title: option.title,
                                  action: #selector(selectLanguage(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            if option.isSelected { item.state = .on }
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // 润色 — 顶层项，状态写在标题里（和 引擎：/语言： 统一）
        let llmItem = NSMenuItem(title: "润色：\(prefs.llmEnabled ? "开启" : "关闭")",
                                 action: #selector(toggleLLM),
                                 keyEquivalent: "")
        llmItem.image = menuIcon("sparkles")
        llmItem.target = self
        menu.addItem(llmItem)

        menu.addItem(.separator())

        // 设置 — 热键 + LLM 配置。⌘, 是 macOS 惯例。
        let settingsItem = NSMenuItem(title: "设置…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.image = menuIcon("gearshape")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "关于",
                               action: #selector(showAbout),
                               keyEquivalent: "")
        about.image = menuIcon("info.circle")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.image = menuIcon("power")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              raw != LanguageMenu.autoIdentifier else { return }
        prefs.language = raw
        speech.setLanguage(raw)
        rebuildMenu()
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let e = Engine(rawValue: raw),
              e != prefs.engine else { return }
        prefs.engine = e
        speech = SpeechBackendFactory.make(engine: e, language: prefs.language)
        sonioxBackendDirty = false
        if e == .doubao { DoubaoCredentialStore.shared.warmup() }
        rebuildMenu()
    }

    @objc private func resetDoubaoCredentials() {
        let alert = NSAlert()
        alert.messageText = "Reset Doubao credentials?"
        alert.informativeText = "Deletes the cached device_id and token, then re-registers on next dictation. Use this if you see errors like 'exceedconcurrentquota'."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            await DoubaoCredentialStore.shared.reset()
            if prefs.engine == .doubao { DoubaoCredentialStore.shared.warmup() }
        }
    }

    @objc private func toggleLLM() {
        prefs.llmEnabled.toggle()
        rebuildMenu()
    }

    @objc private func handleLLMEnabledChanged() {
        // The settings pane already wrote `prefs.llmEnabled`; just refresh the
        // menu so its "润色：开启/关闭" label stays in sync.
        rebuildMenu()
    }

    /// Show/hide the Dock icon at runtime and persist the choice.
    private func setDockIconVisible(_ visible: Bool) {
        prefs.showDockIcon = visible
        applyDockIconVisibility()
    }

    /// Show/hide the menu-bar status item at runtime and persist the choice.
    private func setMenuBarIconVisible(_ visible: Bool) {
        prefs.showMenuBarIcon = visible
        statusItem.isVisible = visible
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let actions = SettingsActions(
                isLaunchAtLoginEnabled: { [launchAtLogin] in launchAtLogin.isEnabled },
                setLaunchAtLogin: { [launchAtLogin] enabled in try launchAtLogin.setEnabled(enabled) },
                isDockIconVisible: { [weak self] in self?.prefs.showDockIcon ?? false },
                setDockIconVisible: { [weak self] visible in self?.setDockIconVisible(visible) },
                isMenuBarIconVisible: { [weak self] in self?.prefs.showMenuBarIcon ?? true },
                setMenuBarIconVisible: { [weak self] visible in self?.setMenuBarIconVisible(visible) },
                resetDoubaoCredentials: { [weak self] in self?.resetDoubaoCredentials() }
            )
            settingsWindow = SettingsWindowFactory.create(llmRefiner: llm, actions: actions)
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Dousha",
            .applicationVersion: "1.0",
            .credits: NSAttributedString(
                string: "Hold a modifier key (or tap in toggle mode) to dictate. Release to paste.",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Permissions

    private func requestSpeechAndMicPermissions() {
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
            onStart: { [weak self] in self?.handleStart() },
            onStop:  { [weak self] in self?.handleStop() }
        )
        if !monitor.start() {
            doushaLog("[Dousha] AppDelegate.startHotkeyMonitor: monitor.start() returned false — will retry in 3s")
            // Most likely Accessibility permission isn't granted yet. Retry so
            // the user can grant it without restarting the app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.startHotkeyMonitor()
            }
            return
        }
        hotkey = monitor
        doushaLog("[Dousha] AppDelegate.startHotkeyMonitor: monitor installed successfully")
    }

    @objc private func handleHotkeyConfigChanged() {
        hotkey?.stop()
        hotkey = nil
        startHotkeyMonitor()
        rebuildMenu()
    }

    @objc private func handleCancelHotkeyConfigChanged() {
        cancelKey?.stop()
        cancelKey = nil
        startCancelKeyMonitor()
    }

    @objc private func handleSonioxConfigChanged() {
        // Rebuild the backend so a changed API key takes effect; only matters
        // while Soniox is the active engine (the factory reads the key at
        // construction).
        guard prefs.engine == .soniox else { return }
        // A session is live — can't stomp it. Defer the rebuild to the next
        // start so the next recording doesn't reuse the stale-key backend.
        guard status == .idle || isErrorStatus(status) else {
            sonioxBackendDirty = true
            return
        }
        speech = SpeechBackendFactory.make(engine: .soniox, language: prefs.language)
        sonioxBackendDirty = false
        rebuildMenu()
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
        let flag = isRecordingFlag
        let monitor = CancelKeyMonitor(
            keyCode: kc,
            shouldFire: { flag.value() },
            onFire: { [weak self] in self?.handleCancel() }
        )
        if !monitor.start() {
            doushaLog("[Dousha] CancelKeyMonitor: start() failed — retrying in 3s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.startCancelKeyMonitor()
            }
            return
        }
        cancelKey = monitor
        doushaLog("[Dousha] CancelKeyMonitor installed for kc=\(kc)")
    }

    private func handleCancel() {
        doushaLog("[Dousha] handleCancel current status=\(status)")
        // Cancel only meaningful during .recording. Past that point either the
        // packet is already in flight (transcribing) or text is already pasted
        // (injecting), and there's nothing left to discard. Pressing cancel
        // during those states is a deliberate no-op so the user's Esc still
        // passes through to whatever else might respond to it.
        guard status == .recording else {
            doushaLog("[Dousha] handleCancel REJECTED (status=\(status))")
            return
        }
        // Bump BEFORE calling cancel() so any in-flight completion that races
        // sees the new token and short-circuits. Backend cancel paths are
        // best-effort about not firing callbacks, but the token is the
        // belt-and-braces guard at the AppDelegate boundary.
        sessionToken &+= 1
        speech.cancel()
        // Backend cancel returns immediately but the actual teardown runs
        // asynchronously (DoubaoASR enqueues a Task). Refuse the next start
        // for a short window so we don't race a fresh `start()` against the
        // still-draining cancel — DoubaoASR._start would observe isRunning=true
        // and silently no-op, leaving the UI in .recording but the backend dead.
        nextStartAllowedAt = Date(timeIntervalSinceNow: Self.cancelTeardownGuard)
        status = .idle
    }

    private func handleStart() {
        doushaLog("[Dousha] AppDelegate.handleStart: current status=\(status)")
        guard status == .idle || isErrorStatus(status) else {
            doushaLog("[Dousha] AppDelegate.handleStart: REJECTED (status=\(status))")
            return
        }
        // Defer if a recent cancel hasn't finished tearing down. Without this,
        // a fast Esc-then-hotkey sequence would race the backend's async
        // cancel and start would silently no-op.
        if let allowedAt = nextStartAllowedAt, allowedAt > Date() {
            let delay = allowedAt.timeIntervalSinceNow
            doushaLog("[Dousha] handleStart deferred \(Int(delay * 1000))ms for cancel teardown")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.handleStart()
            }
            return
        }
        nextStartAllowedAt = nil
        // A Soniox key change arrived mid-session and the rebuild was deferred;
        // apply it now so this recording uses the current key.
        if sonioxBackendDirty, prefs.engine == .soniox {
            speech = SpeechBackendFactory.make(engine: .soniox, language: prefs.language)
            sonioxBackendDirty = false
        }
        status = .recording
        doushaLog("[Dousha] AppDelegate.handleStart: engine=\(prefs.engine.rawValue) language=\(prefs.language)")
        speech.setLanguage(prefs.language)
        hudModel.resetLevels()
        hudModel.resetTranscript()

        let myToken = sessionToken
        speech.start(
            onPartial: { [weak self] partial in
                DispatchQueue.main.async {
                    guard let self = self, self.sessionToken == myToken else { return }
                    // Drop late partials once we've left .recording. sessionToken
                    // is bumped only on cancel, not normal stop, so a batch the
                    // backend dispatched just before stop() can land here AFTER
                    // setFinalTranscript — this gate stops it clobbering the final.
                    guard self.status == .recording else { return }
                    self.hudModel.updateTranscript(partial)
                }
            },
            onAudioLevel: { [weak self] level in
                DispatchQueue.main.async {
                    guard let self = self, self.sessionToken == myToken else { return }
                    self.hudModel.pushLevel(level)
                }
            },
            onError: { [weak self] error in
                doushaLog("[Dousha] recognition error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // Drop stale errors from a canceled or already-finished
                    // session — otherwise a late TaskFailed from the server
                    // would flash the HUD red after the user explicitly
                    // canceled. The Doubao/Apple backends both *attempt* to
                    // suppress these at the source (Apple via sessionGen,
                    // Doubao by nil-ing onError in _cancel), so this is a
                    // belt-and-braces guard for paths that escape both layers
                    // (e.g., events queued onto main before cancel ran).
                    guard self.sessionToken == myToken else {
                        doushaLog("[Dousha] dropping stale error from superseded session")
                        return
                    }
                    self.transitionToError(error.localizedDescription)
                }
            }
        )
    }

    private func handleStop() {
        doushaLog("[Dousha] AppDelegate.handleStop: current status=\(status)")
        guard status == .recording else {
            doushaLog("[Dousha] AppDelegate.handleStop: REJECTED (status=\(status))")
            return
        }
        status = .transcribing
        let myToken = sessionToken
        speech.stop { [weak self] result in
            doushaLog("[Dousha] AppDelegate: speech.stop completion fired (text.len=\(result.text.count) dur=\(String(format: "%.1f", result.audioDuration))s lastTranscriptAge=\(result.lastTranscriptAge.map { String(format: "%.1f", $0) } ?? "nil") lastRespAge=\(result.lastResponseAge.map { String(format: "%.1f", $0) } ?? "nil"))")
            DispatchQueue.main.async {
                guard let self = self else { return }
                // If the user (or HUD button) canceled while we were waiting
                // for the backend to finish, the token has advanced. Drop the
                // completion without injecting.
                guard self.sessionToken == myToken else {
                    doushaLog("[Dousha] stop completion superseded by cancel — dropping")
                    return
                }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.status = .idle
                    return
                }
                self.hudModel.setFinalTranscript(text)
                self.refineAndInject(text)
            }
        }
    }

    private func refineAndInject(_ text: String) {
        let refiner = TextRefiner(baseURL: prefs.llmBaseURL,
                                  apiKey: prefs.llmAPIKey,
                                  model: prefs.llmModel)

        // Off: LLM disabled or unconfigured — paste raw, done.
        guard prefs.llmEnabled, refiner.isConfigured else {
            injectAndFinish(text)
            return
        }

        switch prefs.refineMode {
        case .immediate:
            // Wait for the polished text, then paste it (fall back to raw on failure).
            Task {
                let refined = await refiner.refine(text)
                DispatchQueue.main.async {
                    self.injectAndFinish(refined ?? text)
                }
            }

        case .deferred:
            // Paste raw immediately; quietly replace the clipboard with the
            // polished text when it arrives. injectAndFinish already left raw on
            // the clipboard, so the user can re-paste to pick up the refined copy.
            injectAndFinish(text)
            refiner.refineLater(text) { refined in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(refined, forType: .string)
                doushaLog("[Dousha] deferred refine wrote refined text to clipboard (len=\(refined.count))")
            }
        }
    }

    private func injectAndFinish(_ text: String) {
        doushaLog("[Dousha] AppDelegate.injectAndFinish: text=\"\(text.prefix(60))\"")
        status = .injecting
        injector.inject(text)
        // Brief green flash then back to idle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.status = .idle
        }
    }

    private func transitionToError(_ message: String) {
        // Don't keep replacing the error on every cascading event — the
        // upstream DoubaoASR can emit a flood of "expected seq=1" responses
        // after a single session goes bad, and each one would re-defer the
        // idle reset.
        if case .error = status { return }

        status = .error(message)
        // Clear any lingering interim so the error state falls back to the logo
        // placeholder + yellow glow rather than showing stale, unusable text.
        hudModel.resetTranscript()

        // Critical: release the mic / WebSocket. Without this, the speech
        // backend keeps holding the audio device, and the next handleStart
        // would call speech.start on top of an already-live session — the
        // user sees "press key, nothing happens".
        speech.stop { _ in }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self else { return }
            if self.isErrorStatus(self.status) {
                self.status = .idle
            }
        }
    }

    private func isErrorStatus(_ s: RecordingStatus) -> Bool {
        if case .error = s { return true }
        return false
    }
}
