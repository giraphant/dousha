import Cocoa
import DoubaoASR

enum AboutPanel {
    static func applicationVersion(bundle: Bundle = .main) -> String {
        if let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty {
            return version
        }
        if let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !build.isEmpty {
            return build
        }
        return ""
    }
}

/// Owns the menu-bar status item: its icon, the dropdown menu, and every menu
/// action (engine / language pick, LLM toggle, Doubao reset, About). Extracted
/// from `AppDelegate` (QUA-163 Phase 2).
///
/// It reads `Preferences.shared` and `DoubaoCredentialStore.shared` directly,
/// the same as the rest of the app, and reuses `LanguageMenu` for the language
/// option logic. The one effect it can't perform itself — opening the Settings
/// window, which `AppDelegate` owns along with its `SettingsActions` wiring — is
/// injected as a closure.
@MainActor
final class MenuBarController {
    private var statusItem: NSStatusItem!
    private let prefs = Preferences.shared
    private let openSettingsAction: () -> Void

    init(openSettings: @escaping () -> Void) {
        self.openSettingsAction = openSettings
    }

    // MARK: - Setup

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            if let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                // MenuIcon.png is cropped tight to the glyph (no transparent
                // border), so the status item only adds its own padding — one
                // layer, matching system icons. Size to a standard 18pt menu-bar
                // height and derive the width from the glyph's aspect ratio so a
                // non-square glyph isn't stretched.
                let targetHeight: CGFloat = 18
                let aspect = img.size.height > 0 ? img.size.width / img.size.height : 1
                img.size = NSSize(width: targetHeight * aspect, height: targetHeight)
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

    /// Show/hide the menu-bar status item at runtime. Called by `AppDelegate`'s
    /// `SettingsActions` when the user toggles the menu-bar icon in Settings.
    func setIconVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    // MARK: - Menu construction

    /// Builds an SF Symbol image rendered as a template (auto light/dark) at menu size.
    private func menuIcon(_ symbol: String) -> NSImage? {
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        img.isTemplate = true
        return img
    }

    func rebuildMenu() {
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

    // MARK: - Actions

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

    /// Confirm + reset cached Doubao credentials. Internal (not private) because
    /// `AppDelegate`'s `SettingsActions` forwards the Settings-pane reset here.
    @objc func resetDoubaoCredentials() {
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

    @objc private func openSettings() {
        openSettingsAction()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Dousha",
            .applicationVersion: AboutPanel.applicationVersion(),
            .credits: NSAttributedString(
                string: "Hold a modifier key (or tap in toggle mode) to dictate. Release to paste.",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
