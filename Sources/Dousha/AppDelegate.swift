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
    private let focusTracker = AppFocusTracker(selfBundleId: "com.dousha.app")
    private let incompleteDetector = IncompleteTranscriptDetector()

    private var status: RecordingStatus = .idle {
        didSet {
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
        requestSpeechAndMicPermissions()

        focusTracker.onChange = { [weak self] focus in
            self?.hudModel.focus = focus
        }
        hudModel.focus = focusTracker.current
        focusTracker.start()

        startHotkeyMonitor()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotkeyConfigChanged),
            name: .doushaHotkeyConfigChanged,
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

    private func handleStart() {
        doushaLog("[Dousha] AppDelegate.handleStart: current status=\(status)")
        guard status == .idle || isErrorStatus(status) else {
            doushaLog("[Dousha] AppDelegate.handleStart: REJECTED (status=\(status))")
            return
        }
        status = .recording
        doushaLog("[Dousha] AppDelegate.handleStart: engine=\(prefs.engine.rawValue) language=\(prefs.language)")
        speech.setLanguage(prefs.language)
        hudModel.resetLevels()

        speech.start(
            onPartial: { _ in
                // v1 HUD does not display partial transcript text.
            },
            onAudioLevel: { [weak self] level in
                DispatchQueue.main.async { self?.hudModel.pushLevel(level) }
            },
            onError: { [weak self] error in
                doushaLog("[Dousha] recognition error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.transitionToError(error.localizedDescription)
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
        speech.stop { [weak self] result in
            doushaLog("[Dousha] AppDelegate: speech.stop completion fired (text.len=\(result.text.count) dur=\(String(format: "%.1f", result.audioDuration))s lastTranscriptAge=\(result.lastTranscriptAge.map { String(format: "%.1f", $0) } ?? "nil") lastRespAge=\(result.lastResponseAge.map { String(format: "%.1f", $0) } ?? "nil"))")
            DispatchQueue.main.async {
                guard let self = self else { return }
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
