import Cocoa
import SwiftUI
import Speech
import AVFoundation
import ApplicationServices
import DoubaoASR

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

    private var status: RecordingStatus = .idle {
        didSet {
            hudModel.status = status
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

        // LLM Refinement submenu
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
        llmMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        llmMenu.addItem(settingsItem)
        llmItem.submenu = llmMenu
        menu.addItem(llmItem)

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
        let monitor = HotkeyMonitor(
            config: prefs.hotkey,
            onStart: { [weak self] in self?.handleStart() },
            onStop:  { [weak self] in self?.handleStop() }
        )
        if !monitor.start() {
            // Most likely Accessibility permission isn't granted yet. Retry so
            // the user can grant it without restarting the app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.startHotkeyMonitor()
            }
            return
        }
        hotkey = monitor
    }

    @objc private func handleHotkeyConfigChanged() {
        hotkey?.stop()
        hotkey = nil
        startHotkeyMonitor()
        rebuildMenu()
    }

    private func handleStart() {
        guard status == .idle || isErrorStatus(status) else { return }
        status = .recording
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
                NSLog("[Dousha] recognition error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.transitionToError(error.localizedDescription)
                }
            }
        )
    }

    private func handleStop() {
        guard status == .recording else { return }
        status = .transcribing
        speech.stop { [weak self] finalText in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !text.isEmpty else {
                    self.status = .idle
                    return
                }

                if self.prefs.llmEnabled && self.llm.isConfigured {
                    self.llm.refine(text) { result in
                        DispatchQueue.main.async {
                            let final: String
                            switch result {
                            case .success(let refined):
                                final = refined
                            case .failure(let err):
                                NSLog("[Dousha] LLM refine failed: \(err.localizedDescription)")
                                final = text
                            }
                            self.injectAndFinish(final)
                        }
                    }
                } else {
                    self.injectAndFinish(text)
                }
            }
        }
    }

    private func injectAndFinish(_ text: String) {
        status = .injecting
        injector.inject(text)
        // Brief green flash then back to idle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.status = .idle
        }
    }

    private func transitionToError(_ message: String) {
        status = .error(message)
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
