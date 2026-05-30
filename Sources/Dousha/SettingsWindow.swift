import Cocoa
import CoreGraphics
import SwiftUI
import TalkerCommonSync
import SonioxASR

enum SettingsWindowFactory {
    static func create(llmRefiner: LLMRefiner, actions: SettingsActions) -> NSWindow {
        let view = SettingsView(llmRefiner: llmRefiner, actions: actions)
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
    case enhance

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "常规设置"
        case .model:   return "听写模型"
        case .enhance: return "智能增强"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .model:   return "waveform"
        case .enhance: return "sparkles"
        }
    }
}

struct SettingsView: View {
    let llmRefiner: LLMRefiner
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

    // 听写模型 — 词库
    @State private var glossaryEnabled: Bool = Preferences.shared.glossaryEnabled
    @State private var glossaryTerms: [String] = Preferences.shared.glossaryTerms
    @State private var newTerm: String = ""

    init(llmRefiner: LLMRefiner, actions: SettingsActions) {
        self.llmRefiner = llmRefiner
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
        case .general: generalPane
        case .model:   modelPane
        case .enhance: enhancePane
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
    }

    private var modelPane: some View {
        Form {
            Section("引擎路由") {
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
                LabeledContent("API 密钥") {
                    HStack(spacing: 6) {
                        SecureField("soniox API key", text: $sonioxAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                        Button("清除") { sonioxAPIKey = "" }
                            .help("删除已保存的 Soniox API 密钥")
                    }
                }
                if !sonioxStatus.isEmpty {
                    Text(sonioxStatus)
                        .font(.callout)
                        .foregroundStyle(sonioxStatusIsError ? .red : .green)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(isTestingSoniox ? "测试中…" : "测试") { testSoniox() }
                        .disabled(isTestingSoniox || sonioxAPIKey.isEmpty)
                    Spacer()
                    Button("保存") { save() }
                        .keyboardShortcut(.defaultAction)
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

            Divider().padding(.vertical, 4)

            Text("词库")
                .font(.title3).bold()
            Text("把常用术语、专有名词加进词库，识别时会优先往这些词上靠，提高准确率。对豆包和 Soniox 引擎都生效，下一次录音起作用。Soniox 用词表（terms）偏置，效果通常更明显。")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Toggle("启用词库", isOn: $glossaryEnabled)
                    .onChange(of: glossaryEnabled) { _, newValue in
                        Preferences.shared.glossaryEnabled = newValue
                    }

                // Only the term editor is gated by the toggle — the toggle itself
                // must stay enabled so the user can turn the feature on.
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        TextField("添加术语…", text: $newTerm)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                            .onSubmit { addTerm() }
                        Button("添加") { addTerm() }
                            .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if glossaryTerms.isEmpty {
                        Text("词库为空。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        // Explicit per-row delete button. macOS List `.onDelete`
                        // gives no usable affordance (no swipe-to-delete), so a
                        // trailing remove button is the reliable way to delete.
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(glossaryTerms.enumerated()), id: \.offset) { index, term in
                                    HStack {
                                        Text(term)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Button {
                                            removeTerm(at: index)
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("删除「\(term)」")
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    if index < glossaryTerms.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                        }
                        .frame(height: 140)
                        .frame(maxWidth: .infinity)
                        .border(Color.gray.opacity(0.2))
                    }
                }
                .disabled(!glossaryEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !glossaryTerms.contains(term) else { return }
        glossaryTerms.append(term)
        newTerm = ""
        Preferences.shared.glossaryTerms = glossaryTerms
    }

    private func removeTerm(at index: Int) {
        guard glossaryTerms.indices.contains(index) else { return }
        glossaryTerms.remove(at: index)
        Preferences.shared.glossaryTerms = glossaryTerms
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
                LabeledContent("API 地址") {
                    TextField("https://api.openai.com/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }
                LabeledContent("API 密钥") {
                    HStack(spacing: 6) {
                        SecureField("sk-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                        Button("清除") { apiKey = "" }
                            .help("删除已保存的 API 密钥")
                    }
                }
                LabeledContent("模型") {
                    TextField("gpt-4o-mini", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }
                LabeledContent("校正模式") {
                    Picker("", selection: $refineMode) {
                        ForEach(RefineMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: refineMode) { _, newValue in
                        Preferences.shared.refineMode = newValue
                    }
                }
                if !status.isEmpty {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(statusIsError ? .red : .green)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(isTesting ? "测试中…" : "测试") { test() }
                        .disabled(isTesting || apiKey.isEmpty || baseURL.isEmpty || model.isEmpty)
                    Spacer()
                    Button("保存") { save() }
                        .keyboardShortcut(.defaultAction)
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
            Preferences.shared.launchAtLogin = newValue
        } catch {
            launchAtLoginError = "设置开机启动失败：\(error.localizedDescription)"
            // Revert the toggle to the real system state.
            launchAtLogin = actions.isLaunchAtLoginEnabled()
        }
    }

    // MARK: - 润色 / Soniox 操作

    private func test() {
        isTesting = true
        status = "正在测试连接…"
        statusIsError = false
        llmRefiner.test(baseURL: baseURL, apiKey: apiKey, model: model) { result in
            DispatchQueue.main.async {
                isTesting = false
                switch result {
                case .success:
                    status = "连接正常。"
                    statusIsError = false
                case .failure(let err):
                    status = "失败：\(err.localizedDescription)"
                    statusIsError = true
                }
            }
        }
    }

    private func save() {
        Preferences.shared.llmBaseURL = baseURL
        Preferences.shared.llmAPIKey  = apiKey
        Preferences.shared.llmModel   = model
        Preferences.shared.sonioxAPIKey = sonioxAPIKey
        Preferences.shared.sonioxMode = sonioxMode
        status = "已保存。"
        statusIsError = false
        sonioxStatus = "已保存。"
        sonioxStatusIsError = false
        // The active SonioxBackend captured its key at construction; tell the
        // app to rebuild it so a changed key takes effect without a restart.
        NotificationCenter.default.post(name: .doushaSonioxConfigChanged, object: nil)
    }

    private func testSoniox() {
        isTestingSoniox = true
        sonioxStatus = "正在测试连接…"
        sonioxStatusIsError = false
        let key = sonioxAPIKey
        Task {
            let result = await SonioxConnectivityTest.run(apiKey: key)
            await MainActor.run {
                isTestingSoniox = false
                switch result {
                case .success:
                    sonioxStatus = "连接正常。"
                    sonioxStatusIsError = false
                case .failure(let message):
                    sonioxStatus = "失败：\(message)"
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
final class HotkeyRecorder {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onCaptured: ((UInt16) -> Void)?

    func start(onCaptured: @escaping (UInt16) -> Void) {
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
            self?.onCaptured?(captured)
            self?.teardown()
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
    static let doushaSonioxConfigChanged = Notification.Name("DoushaSonioxConfigChanged")
    static let doushaLLMEnabledChanged = Notification.Name("DoushaLLMEnabledChanged")
}
