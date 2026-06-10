import Cocoa
import CoreGraphics
import SwiftUI
import ConcurrencySupport
import SonioxASR

enum SettingsWindowFactory {
    @MainActor
    static func create(actions: SettingsActions) -> NSWindow {
        let view = SettingsView(actions: actions)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "常规设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        let toolbar = NSToolbar(identifier: "DoushaSettingsToolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 680, height: 460))
        window.minSize = NSSize(width: 560, height: 400)
        window.setFrameAutosaveName("DoushaSettingsWindow")
        return window
    }
}

/// Sidebar categories. Engine/language quick-switching deliberately stays in
/// the menu bar; these panes are pure configuration.
private enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case model
    case glossary
    case enhance

    var id: Self { self }

    var title: String {
        switch self {
        case .general:  return "常规设置"
        case .model:    return "听写模型"
        case .glossary: return "个性词库"
        case .enhance:  return "智能增强"
        }
    }

    var symbol: String {
        switch self {
        case .general:  return "gearshape"
        case .model:    return "waveform"
        case .glossary: return "character.book.closed"
        case .enhance:  return "sparkles"
        }
    }
}

struct SettingsView: View {
    let actions: SettingsActions

    @State private var selectedPane: SettingsPane? = .general

    // 常规 — 热键
    @State private var hotkeyKeyCode: UInt16 = Preferences.shared.hotkey.keyCode
    @State private var hotkeyMode: HotkeyMode = Preferences.shared.hotkey.mode
    @State private var isRecordingHotkey: Bool = false
    private let recorder = HotkeyRecorder()

    // 常规 — 取消键
    @State private var cancelHotkey: CancelHotkeyConfig = Preferences.shared.cancelHotkey
    @State private var isRecordingCancelHotkey: Bool = false
    private let cancelRecorder = CancelKeyRecorder()

    // 常规 — 系统开关
    @State private var launchAtLogin: Bool
    @State private var launchAtLoginError: String = ""
    @State private var showDockIcon: Bool
    @State private var showMenuBarIcon: Bool

    // 智能增强 — 润色
    @State private var llmEnabled: Bool = Preferences.shared.llmEnabled
    @State private var baseURL: String = Preferences.shared.llmBaseURL
    @State private var apiKey:  String = Preferences.shared.llmAPIKey
    @State private var model:   String = Preferences.shared.llmModel
    @State private var refineMode: RefineMode = Preferences.shared.refineMode
    @State private var status: String = ""
    @State private var statusIsError: Bool = false
    @State private var isTesting: Bool = false

    // 听写模型 — Soniox
    @State private var sonioxAPIKey: String = Preferences.shared.sonioxAPIKey
    @State private var sonioxMode: SonioxMode = Preferences.shared.sonioxMode
    @State private var sonioxStatus: String = ""
    @State private var sonioxStatusIsError: Bool = false
    @State private var isTestingSoniox: Bool = false

    // 听写模型 — 多引擎路由 (QUA-145). The parallel-active set is derived as the
    // union of these three slots, so there's no separate "active" control.
    @State private var chineseEngine: Engine = Preferences.shared.chineseEngine
    @State private var englishEngine: Engine = Preferences.shared.englishEngine
    @State private var mixedEngine: Engine = Preferences.shared.mixedEngine
    // Primary language steers which slot is the primary engine (HUD source).
    // 混合 ≡ 自动, so the only meaningful primaries are 中文 / 英文 — normalise any
    // stored locale (an Apple single-engine run may have left zh-TW/ja/ko) to one
    // of the two: en-* → 英文, anything else → 中文.
    @State private var primaryLanguage: Language =
        Preferences.shared.language.hasPrefix("en") ? .en_US : .zh_CN

    // 个性词库 — free-text editor; terms are parsed out of `glossaryText` on
    // change. Seeded from the stored terms joined by 顿号.
    @State private var glossaryEnabled: Bool = Preferences.shared.glossaryEnabled
    @State private var glossaryText: String = GlossaryText.format(Preferences.shared.glossaryTerms)

    init(actions: SettingsActions) {
        self.actions = actions
        _launchAtLogin = State(initialValue: actions.isLaunchAtLoginEnabled())
        _showDockIcon = State(initialValue: actions.isDockIconVisible())
        _showMenuBarIcon = State(initialValue: actions.isMenuBarIconVisible())
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detail
                .navigationTitle((selectedPane ?? .general).title)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedPane ?? .general {
        case .general:  generalPane
        case .model:    modelPane
        case .glossary: glossaryPane
        case .enhance:  enhancePane
        }
    }

    // MARK: - 常规设置

    private var generalPane: some View {
        Form {
            Section("启动行为") {
                Toggle("开机时启动豆沙", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        applyLaunchAtLogin(newValue)
                    }
                if !launchAtLoginError.isEmpty {
                    Text(launchAtLoginError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("显示") {
                Toggle("显示程序坞图标", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, newValue in
                        actions.setDockIconVisible(newValue)
                    }
                Toggle("显示状态栏图标", isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { _, newValue in
                        actions.setMenuBarIconVisible(newValue)
                    }
                Text("两者都隐藏后，可从 Finder 或聚焦搜索重新打开豆沙以再次显示本窗口。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("热键") {
                LabeledContent("触发键") {
                    HStack(spacing: 8) {
                        Text(HotkeyMonitor.displayName(forKeyCode: hotkeyKeyCode))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12)))
                        Button(isRecordingHotkey ? "按下修饰键…" : "录制") { toggleRecording() }
                    }
                }
                Picker("模式", selection: $hotkeyMode) {
                    Text("长按说话").tag(HotkeyMode.pushToTalk)
                    Text("切换").tag(HotkeyMode.toggle)
                }
                .pickerStyle(.segmented)
                .onChange(of: hotkeyMode) { _, newMode in
                    let cfg = HotkeyConfig(keyCode: Preferences.shared.hotkey.keyCode, mode: newMode)
                    Preferences.shared.hotkey = cfg
                    NotificationCenter.default.post(name: .doushaHotkeyConfigChanged, object: nil)
                }
                Text("长按说话：按住时录音；切换：每次按下开始/停止。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("取消") {
                LabeledContent("取消键") {
                    HStack(spacing: 8) {
                        Text(cancelHotkey.displayName)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12)))
                        Button(isRecordingCancelHotkey ? "按任意键…" : "录制") { toggleCancelHotkeyRecording() }
                        Button("关闭") {
                            cancelHotkey = .disabled
                            Preferences.shared.cancelHotkey = .disabled
                            NotificationCenter.default.post(name: .doushaCancelHotkeyConfigChanged, object: nil)
                        }
                        .disabled(!cancelHotkey.isEnabled)
                    }
                }
                Text("取消会丢弃当前录音且不转写。仅在录音时生效，其余情况下按键正常透传。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 听写模型

    @ViewBuilder private func engineOptions() -> some View {
        ForEach(Engine.allCases, id: \.self) { e in
            Text(e.displayName).tag(e)
        }
    }

    /// Persist the three slots and recompute the active set as their union.
    private func persistRouting() {
        Preferences.shared.chineseEngine = chineseEngine
        Preferences.shared.englishEngine = englishEngine
        Preferences.shared.mixedEngine = mixedEngine
        let active = Engine.allCases.filter {
            $0 == chineseEngine || $0 == englishEngine || $0 == mixedEngine
        }
        Preferences.shared.activeEngines = active
        NotificationCenter.default.post(name: .doushaEngineRoutingChanged, object: nil)
    }

    private var modelPane: some View {
        Form {
            Section("引擎路由") {
                Picker("主要语言", selection: $primaryLanguage) {
                    Text("中文").tag(Language.zh_CN)
                    Text("英文").tag(Language.en_US)
                }
                .pickerStyle(.segmented)
                .onChange(of: primaryLanguage) { _, newValue in
                    Preferences.shared.language = newValue.rawValue
                    NotificationCenter.default.post(name: .doushaEngineRoutingChanged, object: nil)
                }
                Picker("中文", selection: $chineseEngine) { engineOptions() }
                    .onChange(of: chineseEngine) { _, _ in persistRouting() }
                Picker("英文", selection: $englishEngine) { engineOptions() }
                    .onChange(of: englishEngine) { _, _ in persistRouting() }
                Picker("中英混合", selection: $mixedEngine) { engineOptions() }
                    .onChange(of: mixedEngine) { _, _ in persistRouting() }
                Text("按语言把识别结果路由到对应引擎。用到的引擎会在录音时并行运行——例如「中文→豆包、英文→Soniox」就会同时跑两家，停录后按整段语言占比挑一家的结果。三个都选同一个引擎即单引擎、零额外开销。主要语言（菜单「语言」）对应的引擎为主引擎，其实时字幕显示在悬浮窗。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Soniox") {
                Picker("模式", selection: $sonioxMode) {
                    Text("实时").tag(SonioxMode.realtime)
                    Text("高精度（异步）").tag(SonioxMode.async)
                }
                .pickerStyle(.segmented)
                .onChange(of: sonioxMode) { _, newValue in
                    Preferences.shared.sonioxMode = newValue
                }
                LabeledContent("API 密钥") {
                    HStack(spacing: 6) {
                        SecureField("", text: $sonioxAPIKey)
                            .disableAutocorrection(true)
                        Button("清除") { sonioxAPIKey = "" }
                            .help("删除已保存的 Soniox API 密钥")
                    }
                }
                HStack {
                    Spacer()
                    testStatusLabel(isTesting: isTestingSoniox,
                                    status: sonioxStatus,
                                    isError: sonioxStatusIsError)
                    Button("保存并测试") { saveAndTestSoniox() }
                        .disabled(isTestingSoniox || sonioxAPIKey.isEmpty)
                }
                Text("Soniox 实时语音转写引擎。自动检测语言，无需选择。在菜单「引擎」中切换到 Soniox 后生效。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("豆包") {
                Button("重置豆包凭据…") { actions.resetDoubaoCredentials() }
                Text("删除缓存的 device_id 与 token，下次听写时重新注册。遇到 exceedconcurrentquota 等错误时使用。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Apple Speech") {
                Text("使用系统内置语音识别，无需额外配置。语言在菜单「语言」中选择。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 个性词库

    private var glossaryPane: some View {
        Form {
            Section("个性词库") {
                Toggle("启用个性词库", isOn: $glossaryEnabled)
                    .onChange(of: glossaryEnabled) { _, newValue in
                        Preferences.shared.glossaryEnabled = newValue
                    }

                // Free-text editor: paste / edit a batch, separated by 顿号 / 逗号 /
                // 换行. Parsed into terms on change; we deliberately don't rewrite
                // the text while editing, so the cursor never jumps. The editor is
                // gated by the toggle; the toggle itself stays enabled.
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $glossaryText)
                            .font(.body)
                            .frame(height: 200)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(nsColor: .separatorColor))
                            )
                            .onChange(of: glossaryText) { _, newValue in
                                Preferences.shared.glossaryTerms = GlossaryText.parse(newValue)
                            }
                        if glossaryText.isEmpty {
                            Text("输入关键词、专业术语…\n示例：布迪厄、哈贝马斯、福柯")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 12)
                                .padding(.leading, 9)
                                .allowsHitTesting(false)
                        }
                    }
                    Text("共 \(GlossaryText.parse(glossaryText).count) 个术语")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!glossaryEnabled)

                Text("把常用术语、专有名词加进词库，用顿号、逗号或换行分隔；识别时会优先往这些词上靠，提高准确率。对豆包和 Soniox 引擎都生效，下一次录音起作用。Soniox 用词表（terms）偏置，效果通常更明显。")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 智能增强

    private var enhancePane: some View {
        Form {
            Section("润色") {
                Toggle("启用润色", isOn: $llmEnabled)
                    .onChange(of: llmEnabled) { _, newValue in
                        Preferences.shared.llmEnabled = newValue
                        NotificationCenter.default.post(name: .doushaLLMEnabledChanged, object: nil)
                    }
                TextField("API 地址", text: $baseURL,
                          prompt: Text("https://api.openai.com/v1"))
                    .disableAutocorrection(true)
                LabeledContent("API 密钥") {
                    HStack(spacing: 6) {
                        SecureField("", text: $apiKey, prompt: Text("sk-…"))
                            .disableAutocorrection(true)
                        Button("清除") { apiKey = "" }
                            .help("删除已保存的 API 密钥")
                    }
                }
                TextField("模型", text: $model, prompt: Text("gpt-4o-mini"))
                    .disableAutocorrection(true)
                Picker("校正模式", selection: $refineMode) {
                    ForEach(RefineMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: refineMode) { _, newValue in
                    Preferences.shared.refineMode = newValue
                }
                HStack {
                    Spacer()
                    testStatusLabel(isTesting: isTesting,
                                    status: status,
                                    isError: statusIsError)
                    Button("保存并测试") { saveAndTestLLM() }
                        .disabled(isTesting || apiKey.isEmpty || baseURL.isEmpty || model.isEmpty)
                }
                Text("使用任意兼容 OpenAI 的对话补全接口来清理听写结果。模型只会修正明显的识别错误，不会改写内容。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .formStyle(.grouped)
    }

    // MARK: - 系统开关

    private func applyLaunchAtLogin(_ newValue: Bool) {
        // Guard against the revert below re-triggering onChange into a loop:
        // if the system already matches, there's nothing to do.
        guard actions.isLaunchAtLoginEnabled() != newValue else {
            launchAtLoginError = ""
            return
        }
        do {
            try actions.setLaunchAtLogin(newValue)
            launchAtLoginError = ""
        } catch {
            launchAtLoginError = "设置开机启动失败：\(error.localizedDescription)"
            // Revert the toggle to the real system state.
            launchAtLogin = actions.isLaunchAtLoginEnabled()
        }
    }

    // MARK: - 润色 / Soniox 操作

    /// Persistent, single-line test result shown beside the 「保存并测试」 button:
    /// a spinner while testing, then a coloured icon + short text.
    @ViewBuilder
    private func testStatusLabel(isTesting: Bool, status: String, isError: Bool) -> some View {
        if isTesting {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("测试中…").foregroundStyle(.secondary)
            }
            .font(.callout)
        } else if !status.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                Text(status).lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(isError ? .red : .green)
            .help(status)
        }
    }

    /// Save the LLM credentials, then test connectivity. Settings persist
    /// regardless of the test outcome; the test result is informational.
    private func saveAndTestLLM() {
        Preferences.shared.llmBaseURL = baseURL
        Preferences.shared.llmAPIKey  = apiKey
        Preferences.shared.llmModel   = model
        test()
    }

    private func test() {
        isTesting = true
        status = ""
        statusIsError = false
        let refiner = TextRefiner(baseURL: baseURL, apiKey: apiKey, model: model)
        Task {
            let result = await refiner.test()
            DispatchQueue.main.async {
                isTesting = false
                switch result {
                case .success:
                    status = "连接正常"
                    statusIsError = false
                case .failure(let err):
                    status = "连接失败：\(err.localizedDescription)"
                    statusIsError = true
                }
            }
        }
    }

    /// Save the Soniox key/mode, then test connectivity.
    private func saveAndTestSoniox() {
        Preferences.shared.sonioxAPIKey = sonioxAPIKey
        Preferences.shared.sonioxMode   = sonioxMode
        testSoniox()
    }

    private func testSoniox() {
        isTestingSoniox = true
        sonioxStatus = ""
        sonioxStatusIsError = false
        let key = sonioxAPIKey
        Task {
            let result = await SonioxConnectivityTest.run(apiKey: key)
            await MainActor.run {
                isTestingSoniox = false
                switch result {
                case .success:
                    sonioxStatus = "连接正常"
                    sonioxStatusIsError = false
                case .failure(let message):
                    sonioxStatus = "连接失败：\(message)"
                    sonioxStatusIsError = true
                }
            }
        }
    }

    private func toggleRecording() {
        if isRecordingHotkey {
            recorder.cancel()
            isRecordingHotkey = false
            return
        }
        isRecordingHotkey = true
        recorder.start { newKeyCode in
            hotkeyKeyCode = newKeyCode
            isRecordingHotkey = false
            let cfg = HotkeyConfig(keyCode: newKeyCode, mode: hotkeyMode)
            Preferences.shared.hotkey = cfg
            NotificationCenter.default.post(name: .doushaHotkeyConfigChanged, object: nil)
        }
    }

    private func toggleCancelHotkeyRecording() {
        if isRecordingCancelHotkey {
            cancelRecorder.cancel()
            isRecordingCancelHotkey = false
            return
        }
        isRecordingCancelHotkey = true
        cancelRecorder.start { newKeyCode in
            let cfg = CancelHotkeyConfig(keyCode: newKeyCode)
            cancelHotkey = cfg
            isRecordingCancelHotkey = false
            Preferences.shared.cancelHotkey = cfg
            NotificationCenter.default.post(name: .doushaCancelHotkeyConfigChanged, object: nil)
        }
    }
}

/// One-shot CGEvent tap that captures the next whitelisted modifier press,
/// then automatically tears down. Used by the Settings "Record" button.
final class HotkeyRecorder: @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onCaptured: (@MainActor (UInt16) -> Void)?

    func start(onCaptured: @escaping @MainActor (UInt16) -> Void) {
        guard eventTap == nil else { return }
        self.onCaptured = onCaptured

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyRecorder>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else {
            doushaLog("[Dousha] HotkeyRecorder: failed to create event tap")
            return
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func cancel() { teardown() }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard HotkeyMonitor.isAllowed(keyCode: keyCode),
              let bit = HotkeyMonitor.modifierMask(forKeyCode: keyCode),
              event.flags.contains(bit) else {
            // Wait for a *press* of a whitelisted modifier — ignore releases and
            // ignore non-whitelisted keys.
            return Unmanaged.passUnretained(event)
        }
        let captured = keyCode
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.onCaptured?(captured)
                self?.teardown()
            }
        }
        return nil
    }

    private func teardown() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        onCaptured = nil
    }
}

extension Notification.Name {
    static let doushaHotkeyConfigChanged = Notification.Name("DoushaHotkeyConfigChanged")
    static let doushaLLMEnabledChanged = Notification.Name("DoushaLLMEnabledChanged")
    /// Posted when the engine routing slots / primary language change in Settings,
    /// so the menu bar can rebuild to reflect the new active set / primary.
    static let doushaEngineRoutingChanged = Notification.Name("DoushaEngineRoutingChanged")
}
