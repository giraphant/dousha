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

    private let viewModel = FloatingViewModel()
    private var floatingWindow: FloatingWindow?

    private var fnMonitor: FnKeyMonitor?
    private var isRecording = false
    private var pendingStop = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        floatingWindow = FloatingWindow(viewModel: viewModel)
        requestSpeechAndMicPermissions()
        startFnMonitor()
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

        let header = NSMenuItem(title: "Dousha — Hold Fn to record", action: nil, keyEquivalent: "")
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
        alert.informativeText = "Deletes the cached device_id and token, then re-registers on next dictation. Use this if you see errors like ‘exceedconcurrentquota’."
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
            .credits: NSAttributedString(string: "Hold Fn to dictate. Release to paste.",
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

    // MARK: - Fn key

    private func startFnMonitor() {
        let monitor = FnKeyMonitor(
            onPress:   { [weak self] in DispatchQueue.main.async { self?.handleFnDown() } },
            onRelease: { [weak self] in DispatchQueue.main.async { self?.handleFnUp() } }
        )
        if !monitor.start() {
            // Likely missing accessibility permission. Retry shortly so the user can grant it
            // and we recover without restarting the app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.startFnMonitor()
            }
            return
        }
        fnMonitor = monitor
    }

    private func handleFnDown() {
        guard !isRecording else { return }
        isRecording = true
        pendingStop = false

        speech.setLanguage(prefs.language)
        viewModel.reset()
        floatingWindow?.show()

        speech.start(
            onPartial: { [weak self] text in
                self?.viewModel.transcript = text
            },
            onAudioLevel: { [weak self] level in
                self?.viewModel.audioLevel = level
            },
            onError: { [weak self] error in
                NSLog("[Dousha] recognition error: \(error.localizedDescription)")
                self?.viewModel.transcript = "⚠︎ \(error.localizedDescription)"
            }
        )
    }

    private func handleFnUp() {
        guard isRecording else { return }
        isRecording = false
        guard !pendingStop else { return }
        pendingStop = true

        speech.stop { [weak self] finalText in
            guard let self = self else { return }
            let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                self.floatingWindow?.hide()
                self.pendingStop = false
                return
            }

            if self.prefs.llmEnabled && self.llm.isConfigured {
                self.viewModel.isRefining = true
                self.llm.refine(text) { result in
                    DispatchQueue.main.async {
                        self.viewModel.isRefining = false
                        let final: String
                        switch result {
                        case .success(let refined):
                            final = refined
                        case .failure(let err):
                            NSLog("[Dousha] LLM refine failed: \(err.localizedDescription)")
                            final = text
                        }
                        self.viewModel.transcript = final
                        self.floatingWindow?.hide {
                            self.injector.inject(final)
                            self.pendingStop = false
                        }
                    }
                }
            } else {
                self.floatingWindow?.hide {
                    self.injector.inject(text)
                    self.pendingStop = false
                }
            }
        }
    }
}
