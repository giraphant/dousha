import Cocoa
import SwiftUI
import Speech
import AVFoundation
// @preconcurrency: kAXTrustedCheckOptionPrompt is an imported global the SDK
// hasn't audited for Sendable; treat the access as a warning, not an error.
@preconcurrency import ApplicationServices
import DoubaoASR
import SonioxASR
import ASRSupport
import TalkerCommonSync

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    private let injector = TextInjector()
    private let prefs = Preferences.shared
    private let launchAtLogin: LaunchAtLoginManaging = LaunchAtLoginController()

    private let hudModel = FloatingHUDModel()
    private var floatingWindow: FloatingWindow?

    private var hotkey: HotkeyMonitor?
    private var cancelKey: CancelKeyMonitor?
    private let focusTracker = AppFocusTracker(selfBundleId: "com.dousha.app")

    private var recording: RecordingController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockIconVisibility()
        installMainMenu()
        setupMenuBar()
        floatingWindow = FloatingWindow(model: hudModel)
        recording = RecordingController(environment: RecordingEnvironment(
            makeBackend: { [prefs] in MultiEngineBackend.fromPreferences(prefs) },
            applyStatusToHUD: { [hudModel] status in hudModel.status = status },
            setHUDVisible: { [weak self] visible in
                if visible { self?.floatingWindow?.show() } else { self?.floatingWindow?.hide() }
            },
            forceDispatcherIdle: { [weak self] in self?.hotkey?.forceDispatcherIdle() },
            resetHUDLevels: { [hudModel] in hudModel.resetLevels() },
            resetHUDTranscript: { [hudModel] in hudModel.resetTranscript() },
            updateHUDTranscript: { [hudModel] partial in hudModel.updateTranscript(partial) },
            pushHUDLevel: { [hudModel] level in hudModel.pushLevel(level) },
            setFinalTranscript: { [hudModel] text in hudModel.setFinalTranscript(text) },
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
        hudModel.onFinish = { [weak self] in self?.recording.stop() }
        hudModel.onCancel = { [weak self] in self?.recording.cancel() }
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
        openSettings()
        return true
    }

    // MARK: - System toggles (Dock icon / menu-bar icon)

    /// Apply the persisted Dock-icon preference to the activation policy.
    private func applyDockIconVisibility() {
        NSApp.setActivationPolicy(prefs.showDockIcon ? .regular : .accessory)
    }

    /// A menu-bar accessory app (`LSUIElement`) gets no main menu by default, so
    /// the standard ⌘X/⌘C/⌘V/⌘A editing shortcuts have nothing to route to in the
    /// responder chain — text fields in the Settings window can't cut/copy/paste/
    /// select-all from the keyboard. Installing a main menu with the standard Edit
    /// items wires those key equivalents to the first responder. The menu itself
    /// stays hidden while the app is an accessory; only its shortcuts are live.
    private func installMainMenu() {
        let mainMenu = NSMenu()
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
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
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
        let engineSummary = prefs.activeEngines.count > 1
            ? prefs.activeEngines.map(\.displayName).joined(separator: "+")
            : prefs.engine.displayName
        let engineItem = NSMenuItem(title: "引擎：\(engineSummary)",
                                    action: nil, keyEquivalent: "")
        engineItem.image = menuIcon("waveform")
        let engineMenu = NSMenu()
        for e in Engine.allCases {
            let item = NSMenuItem(title: e.displayName,
                                  action: #selector(selectEngine(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = e.rawValue
            // Check every active engine; clicking one collapses to single-engine.
            if prefs.activeEngines.contains(e) { item.state = .on }
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
        let langOptions = LanguageMenu.options(activeEngines: prefs.activeEngines,
                                               primaryEngine: prefs.engine,
                                               selectedLanguage: prefs.language)
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
        rebuildMenu()
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let e = Engine(rawValue: raw),
              prefs.activeEngines != [e] else { return }
        // Menu engine pick = single-engine quick switch (collapses the routing
        // slots + active set to this one engine). The guard skips only when we're
        // ALREADY collapsed onto `e` — comparing against `prefs.engine` (the
        // primary slot) wrongly blocked the collapse whenever `e` happened to be
        // the current primary while a secondary engine was still active.
        // Multi-engine routing is set up in Settings. The backend itself is
        // rebuilt at the next recording.start().
        prefs.engine = e
        if prefs.activeEngines.contains(.doubao) { DoubaoCredentialStore.shared.warmup() }
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
            if prefs.activeEngines.contains(.doubao) { DoubaoCredentialStore.shared.warmup() }
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
            settingsWindow = SettingsWindowFactory.create(actions: actions)
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
            doushaLog("[Dousha] AppDelegate.startHotkeyMonitor: monitor.start() returned false — will retry in 3s")
            // Most likely Accessibility permission isn't granted yet. Retry so
            // the user can grant it without restarting the app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.startHotkeyMonitor() }
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

    @objc private func handleEngineRoutingChanged() {
        // Routing slots / primary language changed in Settings. Refresh the menu
        // (engine summary, checkmarks, language) and warm Doubao if now active.
        if prefs.activeEngines.contains(.doubao) { DoubaoCredentialStore.shared.warmup() }
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
        let flag = recording.recordingFlag
        let monitor = CancelKeyMonitor(
            keyCode: kc,
            shouldFire: { flag.value() },
            onFire: { [weak self] in self?.recording.cancel() }
        )
        if !monitor.start() {
            doushaLog("[Dousha] CancelKeyMonitor: start() failed — retrying in 3s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.startCancelKeyMonitor() }
            }
            return
        }
        cancelKey = monitor
        doushaLog("[Dousha] CancelKeyMonitor installed for kc=\(kc)")
    }

}
