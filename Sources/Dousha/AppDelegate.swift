import Cocoa
import SwiftUI
import Speech
import AVFoundation
import ApplicationServices
import DoubaoASR
import TalkerCommonSync

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    private var speech: SpeechBackend = SpeechBackendFactory.make(
        engine: Preferences.shared.engine,
        language: Preferences.shared.language
    )
    private let injector = TextInjector()
    private let llm = LLMRefiner()
    private let prefs = Preferences.shared

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
    private let incompleteDetector = IncompleteTranscriptDetector()

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
        NSApp.setActivationPolicy(.accessory)
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

        if prefs.engine == .doubao { DoubaoCredentialStore.shared.warmup() }
    }

    // MARK: - Menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "mic.fill",
                                accessibilityDescription: "Dousha")
            btn.image?.isTemplate = true
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let triggerLabel = HotkeyMonitor.displayName(forKeyCode: prefs.hotkey.keyCode)
        let modeLabel = prefs.hotkey.mode == .pushToTalk ? "Hold" : "Tap"
        let header = NSMenuItem(title: "Dousha — \(modeLabel) \(triggerLabel) to record",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        // Engine submenu
        let engineItem = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
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
        let resetItem = NSMenuItem(title: "Reset Doubao Credentials…",
                                   action: #selector(resetDoubaoCredentials),
                                   keyEquivalent: "")
        resetItem.target = self
        engineMenu.addItem(resetItem)
        engineItem.submenu = engineMenu
        menu.addItem(engineItem)

        // Language submenu
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for lang in Language.allCases {
            let item = NSMenuItem(title: lang.displayName,
                                  action: #selector(selectLanguage(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = lang.rawValue
            if lang.rawValue == prefs.language { item.state = .on }
            langMenu.addItem(item)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // LLM Refinement submenu (just the toggle + status — Settings is now top-level)
        let llmItem = NSMenuItem(title: "LLM Refinement", action: nil, keyEquivalent: "")
        let llmMenu = NSMenu()
        let toggle = NSMenuItem(title: "Enable LLM Refinement",
                                action: #selector(toggleLLM),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = prefs.llmEnabled ? .on : .off
        llmMenu.addItem(toggle)
        let configured = NSMenuItem(
            title: llm.isConfigured ? "Status: Configured" : "Status: Not configured",
            action: nil, keyEquivalent: "")
        configured.isEnabled = false
        llmMenu.addItem(configured)
        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

        // Re-transcribe Last Recording — manual escape hatch for incomplete detection misses
        let retranscribeItem = NSMenuItem(
            title: "Re-transcribe Last Recording",
            action: #selector(retranscribeLastRecording),
            keyEquivalent: ""
        )
        retranscribeItem.target = self
        // Disable when there's no saved WAV yet, when a session is live, or when the
        // current engine isn't Doubao (Apple backend doesn't save WAVs).
        let canRetry = FileManager.default.fileExists(atPath: DoubaoASR.savedAudioURL.path)
            && prefs.engine == .doubao
            && (status == .idle || isErrorStatus(status))
        retranscribeItem.isEnabled = canRetry
        menu.addItem(retranscribeItem)

        menu.addItem(.separator())

        // Top-level Settings — hosts hotkey + LLM config. ⌘, is the macOS convention.
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Dousha",
                               action: #selector(showAbout),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Dousha",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
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

    @objc private func retranscribeLastRecording() {
        guard status == .idle || isErrorStatus(status) else {
            doushaLog("[Dousha] retranscribe menu rejected — busy (status=\(status))")
            return
        }
        doushaLog("[Dousha] retranscribe menu fired")
        status = .transcribing
        speech.retranscribeLastRecording { [weak self] text in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    doushaLog("[Dousha] retranscribe returned empty — back to idle")
                    self.status = .idle
                    return
                }
                self.refineAndInject(text)
            }
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowFactory.create(llmRefiner: llm)
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
        status = .recording
        doushaLog("[Dousha] AppDelegate.handleStart: engine=\(prefs.engine.rawValue) language=\(prefs.language)")
        speech.setLanguage(prefs.language)
        hudModel.resetLevels()

        let myToken = sessionToken
        speech.start(
            onPartial: { _ in
                // v1 HUD does not display partial transcript text.
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

                // Heuristic: did the stream probably get truncated? If so, hold off
                // injection and re-transcribe from the saved WAV.
                if self.incompleteDetector.isLikelyIncomplete(result: result, language: self.prefs.language) {
                    doushaLog("[Dousha] heuristic flagged incomplete (originalText.len=\(text.count)) — triggering retranscribe")
                    // Keep HUD in transcribing state — don't drop to idle while retrying.
                    self.speech.retranscribeLastRecording { retried in
                        DispatchQueue.main.async {
                            let retriedText = (retried?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                            let finalText: String
                            if let r = retriedText {
                                doushaLog("[Dousha] retranscribe succeeded: original.len=\(text.count) retried.len=\(r.count)")
                                finalText = r
                            } else {
                                doushaLog("[Dousha] retranscribe returned empty — falling back to original (len=\(text.count))")
                                finalText = text
                            }
                            guard !finalText.isEmpty else {
                                self.status = .idle
                                return
                            }
                            self.refineAndInject(finalText)
                        }
                    }
                    return
                }

                guard !text.isEmpty else {
                    self.status = .idle
                    return
                }
                self.refineAndInject(text)
            }
        }
    }

    private func refineAndInject(_ text: String) {
        if self.prefs.llmEnabled && self.llm.isConfigured {
            self.llm.refine(text) { result in
                DispatchQueue.main.async {
                    let final: String
                    switch result {
                    case .success(let refined): final = refined
                    case .failure(let err):
                        doushaLog("[Dousha] LLM refine failed: \(err.localizedDescription)")
                        final = text
                    }
                    self.injectAndFinish(final)
                }
            }
        } else {
            self.injectAndFinish(text)
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
