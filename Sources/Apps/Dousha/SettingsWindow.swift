import Cocoa
import CoreGraphics
import SwiftUI
import Charts
import AVFoundation
import Speech
import ApplicationServices
import ASRSupport
import ConcurrencySupport
import SonioxASR
import MLXASR

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
    case audio
    case model
    case glossary
    case enhance
    case history
    case statistics
    case permissions

    var id: Self { self }

    var title: String {
        switch self {
        case .general:  return "常规设置"
        case .audio:    return "音频设置"
        case .model:    return "听写模型"
        case .glossary: return "个性词库"
        case .enhance:  return "智能增强"
        case .history:  return "历史记录"
        case .statistics: return "统计"
        case .permissions: return "权限"
        }
    }

    var symbol: String {
        switch self {
        case .general:  return "gearshape"
        case .audio:    return "mic"
        case .model:    return "waveform"
        case .glossary: return "character.book.closed"
        case .enhance:  return "sparkles"
        case .history:  return "clock.arrow.circlepath"
        case .statistics: return "chart.bar"
        case .permissions: return "lock.shield"
        }
    }
}

private struct SettingsEngineSheet: Identifiable {
    let engine: Engine
    var id: Engine { engine }
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

    // 智能增强 — 文本格式
    @State private var quoteStyle: TranscriptCorrector.QuoteStyle = Preferences.shared.quoteStyle

    // 智能增强 — 润色
    @State private var llmEnabled: Bool = Preferences.shared.llmEnabled
    @State private var baseURL: String = Preferences.shared.llmBaseURL
    @State private var apiKey:  String = Preferences.shared.llmAPIKey
    @State private var model:   String = Preferences.shared.llmModel
    @State private var llmSystemPrompt: String = Preferences.shared.llmSystemPrompt
    @State private var savedLLMSystemPrompt: String = Preferences.shared.llmSystemPrompt
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

    // Sheets and panes share this owner: dismissal/navigation must not discard
    // unsaved credentials, test results, or model-management state.
    @State private var selectedEngineSheet: SettingsEngineSheet?
    @State private var presentedHelp: String?
    @State private var activeEngines: [Engine] = Preferences.shared.activeEngines
    @State private var qwen3ModelRepoID: String = Preferences.shared.qwen3ModelRepoID
    @State private var modelInventory: [String: MLXModelInventory.Entry] = [:]
    @State private var modelStoreState: MLXModelStore.State = .idle
    @State private var requestedModelRepoID: String?
    @State private var uninstallingModelRepoID: String?
    @State private var modelManagementError = ""

    // 音频设置 — 麦克风选择
    @State private var microphoneUseSystemDefault: Bool = Preferences.shared.microphoneSelection.useSystemDefault
    @State private var microphonePriorityUIDs: [String] = Preferences.shared.microphoneSelection.priorityUIDs
    @State private var availableMicrophones: [AudioInputDevice] = []

    // 音频设置 — 录音时背景音频控制
    @State private var muteSystemAudioDuringRecording: Bool = Preferences.shared.muteSystemAudioDuringRecording
    @State private var pauseMediaDuringRecording: Bool = Preferences.shared.pauseMediaDuringRecording

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

    // MARK: 历史（重新转录）
    @State private var historyLimit: Int = Preferences.shared.historyLimit
    @State private var historyEntries: [RecordingHistoryEntry] = []
    /// Reactive mirror of `actions.canRetranscribe()` — polling it inline in
    /// `.disabled` bakes in whatever the controller status was at render time
    /// and nothing re-renders when the session ends (buttons stuck grey).
    @State private var canRetranscribeNow = true
    private let history = RecordingHistoryStore()

    @State private var stats = DictationStats()
    @State private var confirmingStatsReset = false
    private let statsStore = DictationStatsStore()

    @State private var microphoneStatus: AVAuthorizationStatus = .notDetermined
    @State private var speechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @State private var accessibilityGranted = false

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
        .sheet(item: $selectedEngineSheet) { selection in
            engineSheet(selection.engine)
        }
        .confirmationDialog("重置统计？", isPresented: $confirmingStatsReset) {
            Button("重置统计", role: .destructive) { statsStore.reset() }
        } message: {
            Text("所有听写统计将被清除，历史录音不受影响。")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedPane ?? .general {
        case .general:  generalPane
        case .audio:    audioPane
        case .model:    modelPane
        case .glossary: glossaryPane
        case .enhance:  enhancePane
        case .history:  historyPane
        case .statistics: statisticsPane
        case .permissions: permissionsPane
        }
    }

    // MARK: - 常规设置

    private var generalPane: some View {
        Form {
            Section("启动与显示") {
                Toggle("开机时启动豆沙", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        applyLaunchAtLogin(newValue)
                    }
                if !launchAtLoginError.isEmpty {
                    statusLabel(launchAtLoginError, isError: true)
                }
                Toggle("显示程序坞图标", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, newValue in
                        actions.setDockIconVisible(newValue)
                    }
                Toggle(isOn: $showMenuBarIcon) {
                    Text("显示状态栏图标")
                    Text("均隐藏后，从 Finder 或聚焦搜索重开豆沙")
                }
                .onChange(of: showMenuBarIcon) { _, newValue in
                    actions.setMenuBarIconVisible(newValue)
                }
            }

            Section("热键") {
                LabeledContent("触发键") {
                    HStack(spacing: 8) {
                        Text(HotkeyMonitor.displayName(forKeyCode: hotkeyKeyCode))
                        Button(isRecordingHotkey ? "按下修饰键…" : "录制") { toggleRecording() }
                    }
                }
                Picker("模式", selection: $hotkeyMode) {
                    Text("长按说话（按住录音）").tag(HotkeyMode.pushToTalk)
                    Text("切换（按一下开始／停止）").tag(HotkeyMode.toggle)
                }
                .onChange(of: hotkeyMode) { _, newMode in
                    let cfg = HotkeyConfig(keyCode: Preferences.shared.hotkey.keyCode, mode: newMode)
                    Preferences.shared.hotkey = cfg
                    NotificationCenter.default.post(name: .doushaHotkeyConfigChanged, object: nil)
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(cancelHotkey.displayName)
                        Button(isRecordingCancelHotkey ? "按任意键…" : "录制") { toggleCancelHotkeyRecording() }
                        Button("关闭") {
                            cancelHotkey = .disabled
                            Preferences.shared.cancelHotkey = .disabled
                            NotificationCenter.default.post(name: .doushaCancelHotkeyConfigChanged, object: nil)
                        }
                        .disabled(!cancelHotkey.isEnabled)
                        settingsHelp("取消键仅在录音时丢弃当前录音且不转写。",
                                     details: "取消会丢弃当前录音且不转写。仅在录音时生效，其余情况下按键正常透传。")
                    }
                } label: {
                    Text("取消键")
                    Text("仅在录音时丢弃，不转写")
                }
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
        activeEngines = active
        if active.contains(.qwen3) { MLXModelStore.shared.warmup(Preferences.shared.qwen3Model) }
        NotificationCenter.default.post(name: .doushaEngineRoutingChanged, object: nil)
    }

    // MARK: - 麦克风选择

    /// Devices merged with the stored priority list: known devices ordered by
    /// the saved UIDs, then any remaining devices by the recommended sort. A
    /// saved UID whose device has since vanished is kept as a placeholder so the
    /// user's ordering survives a device being unplugged mid-session.
    private var orderedMicrophones: [AudioInputDevice] {
        AudioInputDevices.orderedInputDevices(availableMicrophones,
                                              priorityUIDs: microphonePriorityUIDs)
    }

    /// The device the next recording will actually open, for the "当前" hint.
    private var activeMicrophoneName: String? {
        guard !microphoneUseSystemDefault else {
            return availableMicrophones.first(where: { $0.isDefaultInput })?.name ?? "系统默认"
        }
        return orderedMicrophones.first?.name
    }

    private func refreshMicrophones() {
        availableMicrophones = AudioInputDevices.currentInputDevices()
    }

    private func persistMicrophoneSelection() {
        Preferences.shared.microphoneSelection = MicrophoneSelectionPreference(
            useSystemDefault: microphoneUseSystemDefault,
            priorityUIDs: microphonePriorityUIDs
        )
        refreshMicrophones()
    }

    private func moveMicrophone(_ device: AudioInputDevice, delta: Int) {
        guard !microphoneUseSystemDefault else { return }
        var uids = microphonePriorityUIDs
        // Rebuild the full ordered UID list (priority UIDs first, then the rest)
        // so a move works even when the row was implicitly added by sort.
        let ordered = orderedMicrophones.map(\.uid)
        uids = ordered
        guard let index = uids.firstIndex(of: device.uid) else { return }
        let newIndex = index + delta
        guard newIndex >= 0, newIndex < uids.count else { return }
        uids.swapAt(index, newIndex)
        microphonePriorityUIDs = uids
        persistMicrophoneSelection()
    }

    @ViewBuilder
    private func microphoneRow(_ device: AudioInputDevice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "mic")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text("\(device.transportDescription) · \(device.inputChannelCount) 通道\(device.isDefaultInput ? " · 系统默认" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { moveMicrophone(device, delta: -1) }) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .help("上移")
            .accessibilityLabel("上移 \(device.name)")
            Button(action: { moveMicrophone(device, delta: 1) }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("下移")
            .accessibilityLabel("下移 \(device.name)")
        }
    }

    private var audioPane: some View {
        Form {
            Section {
                Toggle(isOn: $microphoneUseSystemDefault) {
                    Text("使用系统默认")
                    Text("关闭后按下方顺序选择，下次录音生效")
                }
                .onChange(of: microphoneUseSystemDefault) { _, _ in persistMicrophoneSelection() }

                if orderedMicrophones.isEmpty {
                    Text("未找到可用麦克风。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(orderedMicrophones) { device in
                        microphoneRow(device)
                    }
                    .disabled(microphoneUseSystemDefault)
                }

                if let active = activeMicrophoneName {
                    LabeledContent("当前", value: active)
                }
                Button("刷新设备") { refreshMicrophones() }
            } header: {
                HStack {
                    Text("麦克风")
                    settingsHelp("关闭系统默认后，按上方顺序选择麦克风，下一次录音生效。",
                                 details: "关闭「使用系统默认」后，豆沙会按列表顺序尝试麦克风；内建或外接麦克风会优先尝试。下一次录音起生效。")
                }
            }

            Section {
                Toggle(isOn: $muteSystemAudioDuringRecording) {
                    Text("录音时静音")
                    Text("临时静音系统输出，结束后恢复")
                }
                .onChange(of: muteSystemAudioDuringRecording) { _, newValue in
                    Preferences.shared.muteSystemAudioDuringRecording = newValue
                }
                Toggle(isOn: $pauseMediaDuringRecording) {
                    Text("录音时暂停媒体")
                    Text("暂停正在播放的媒体，结束后恢复")
                }
                .onChange(of: pauseMediaDuringRecording) { _, newValue in
                    Preferences.shared.pauseMediaDuringRecording = newValue
                }
            } header: {
                HStack {
                    Text("音频和反馈")
                    settingsHelp("录音时静音或暂停正在播放的媒体，结束后恢复。",
                                 details: "录音时静音会临时静音系统输出并在结束后恢复；暂停媒体会在系统 Now Playing 显示正在播放时暂停，并在录音结束后恢复，未播放时不会启动媒体。少数不发布 Now Playing 状态的应用或网页可能不会被暂停，可同时开启录音时静音作为兜底。系统语音隔离当前不作为可用选项暴露，避免再次切到系统播放/多通道输入。")
                }
            }
        }
        .formStyle(.grouped)
        .task { refreshMicrophones() }
    }

    private var modelPane: some View {
        Form {
            Section {
                Picker(selection: $primaryLanguage) {
                    Text("中文").tag(Language.zh_CN)
                    Text("英文").tag(Language.en_US)
                } label: {
                    Text("主要语言")
                    Text("对应引擎提供悬浮窗实时字幕")
                }
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
            } header: {
                HStack {
                    Text("引擎路由")
                    settingsHelp("用到的引擎会在录音时并行运行，停录后按语言挑选结果。",
                                 details: "按语言把识别结果路由到对应引擎。用到的引擎会在录音时并行运行——例如「中文→豆包、英文→Soniox」就会同时跑两家，停录后按整段语言占比挑一家的结果。三个都选同一个引擎即单引擎、零额外开销。主要语言（菜单「语言」）对应的引擎为主引擎，其实时字幕显示在悬浮窗。")
                }
            }
            Section("引擎") {
                engineRow(.qwen3)
                engineRow(.soniox)
                engineRow(.doubao)
                engineRow(.apple)
            }
        }
        .formStyle(.grouped)
        .task {
            refreshEnginePreferences()
            await observeModelInventory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .doushaEngineRoutingChanged)) { _ in
            refreshEnginePreferences()
        }
    }

    private func engineSummary(_ engine: Engine) -> String {
        let summary: String
        switch engine {
        case .qwen3:
            summary = "本地 · \(selectedQwen3Model.displayName)"
        case .soniox:
            summary = "云端 · \(sonioxMode == .realtime ? "实时" : "高精度（异步）") · \(Preferences.shared.sonioxAPIKey.isEmpty ? "未配置密钥" : "密钥已配置")"
        case .doubao:
            summary = "云端 · 凭据自动管理"
        case .apple:
            summary = "本地 · 系统内置 · 语言在菜单中选择"
        }
        return summary + (activeEngines.contains(engine) ? " · 使用中" : "")
    }

    private func engineRow(_ engine: Engine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: engine.symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine == .apple ? "Apple 听写" : engine.displayName)
                Text(engineSummary(engine))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if engine != .apple {
                Button("选项…") { selectedEngineSheet = SettingsEngineSheet(engine: engine) }
                    .accessibilityLabel("\(engine.displayName)，选项")
                    .accessibilityValue(engineSummary(engine))
            }
        }
        .help(engine == .apple ? "使用系统内置语音识别，无需额外配置。语言在菜单「语言」中选择。" : engineSummary(engine))
    }

    // Computed fragments only: sheet presentation and every editable binding
    // belong to SettingsView, just like the six navigation panes.
    private func engineSheet(_ engine: Engine) -> some View {
        VStack(spacing: 0) {
            Form {
                switch engine {
                case .qwen3: qwen3Settings
                case .soniox: sonioxSettings
                case .doubao: doubaoSettings
                case .apple: EmptyView()
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("完成") { selectedEngineSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: engine == .doubao ? 240 : 420)
    }

    private var sonioxSettings: some View {
        Section {
            Picker(selection: $sonioxMode) {
                Text("实时").tag(SonioxMode.realtime)
                Text("高精度（异步）").tag(SonioxMode.async)
            } label: {
                Text("模式")
                Text("自动检测语言，无需手动选择")
            }
            .onChange(of: sonioxMode) { _, newValue in
                Preferences.shared.sonioxMode = newValue
            }
            LabeledContent("API 密钥") {
                HStack(spacing: 6) {
                    SecureField("", text: $sonioxAPIKey)
                        .disableAutocorrection(true)
                        .accessibilityLabel("Soniox API 密钥")
                    Button("清除", role: .destructive) { sonioxAPIKey = "" }
                        .help("删除已保存的 Soniox API 密钥")
                }
            }
            HStack {
                Spacer()
                Button("保存并测试") { saveAndTestSoniox() }
                    .disabled(isTestingSoniox || sonioxAPIKey.isEmpty)
            }
            if isTestingSoniox || !sonioxStatus.isEmpty {
                statusLabel(isTestingSoniox ? "测试中…" : sonioxStatus,
                            isError: sonioxStatusIsError, isProgress: isTestingSoniox)
            }
        } header: {
            HStack {
                Text("Soniox")
                settingsHelp("Soniox 自动检测语言，无需手动选择。",
                             details: "Soniox 实时语音转写引擎。自动检测语言，无需选择。在菜单「引擎」中切换到 Soniox 后生效。")
            }
        }
    }

    private var doubaoSettings: some View {
        Section("豆包") {
            HStack {
                Button("重置豆包凭据…", role: .destructive) { actions.resetDoubaoCredentials() }
                Spacer()
                settingsHelp("重置后，下次听写时自动重新注册凭据。",
                             details: "删除缓存的 device_id 与 token，下次听写时自动重新注册。遇到 exceedconcurrentquota 等错误时使用。")
            }
        }
    }

    private var selectedQwen3Model: MLXModelDescriptor {
        MLXModelCatalog.all.first { $0.repoID == qwen3ModelRepoID } ?? MLXModelCatalog.defaultModel
    }

    private var isModelOperationPending: Bool {
        if case .loading = modelStoreState { return true }
        return requestedModelRepoID != nil || uninstallingModelRepoID != nil
    }

    private var qwen3Settings: some View {
        Section {
            ForEach(MLXModelCatalog.all, id: \.repoID) { descriptor in
                qwen3ModelRow(descriptor)
            }
            if !modelManagementError.isEmpty {
                statusLabel(modelManagementError, isError: true)
            }
        } header: {
            HStack {
                Text("Qwen3 模型")
                settingsHelp("下载后可离线听写，切换模型在下一次录音生效。",
                             details: "安装会下载并加载模型，首次可能需要几分钟；下载完成后可离线听写。切换模型在下一次录音生效。\n\n已加载的模型暂不可卸载。请先使用另一个模型并等待加载完成，或重新打开豆沙后卸载。")
            }
        }
    }

    private func qwen3ModelRow(_ descriptor: MLXModelDescriptor) -> some View {
        let entry = modelInventory[descriptor.repoID]
        let installed = entry?.isInstalled == true
        let selected = qwen3ModelRepoID == descriptor.repoID
        let loading = modelStoreState == .loading(repoID: descriptor.repoID)
        let loaded = modelStoreState == .ready(repoID: descriptor.repoID)
        let pending = loading || requestedModelRepoID == descriptor.repoID || uninstallingModelRepoID == descriptor.repoID
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button { selectModel(descriptor) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selected ? "checkmark.circle" : "circle")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(descriptor.displayName)
                                .foregroundStyle(.primary)
                            Text(modelSizeLabel(descriptor, entry: entry) + (selected ? " · 使用中" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!installed || selected || isModelOperationPending)
                .accessibilityLabel("使用 \(descriptor.displayName)")
                .accessibilityValue(selected ? "使用中" : (installed ? "已安装" : "尚未安装"))
                Spacer(minLength: 4)
                if pending {
                    statusLabel(uninstallingModelRepoID == descriptor.repoID ? "正在删除…" : (loading ? "下载并加载中…" : "等待模型空闲…"),
                                isProgress: true)
                } else if !installed {
                    Button { installModel(descriptor) } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isModelOperationPending)
                    .help("下载 \(descriptor.displayName)")
                    .accessibilityLabel("下载 \(descriptor.displayName)")
                }
                if installed {
                    Button("删除", role: .destructive) { uninstallModel(descriptor) }
                        .disabled(isModelOperationPending || loaded)
                        .help(loaded ? "模型仍已加载，请先切换模型或重新打开豆沙" : "删除此模型的本地缓存")
                        .accessibilityLabel("删除 \(descriptor.displayName)")
                }
            }
            if case .failed(let repoID, let message) = modelStoreState, repoID == descriptor.repoID {
                HStack(alignment: .top) {
                    statusLabel("加载失败：\(message)", isError: true)
                    Spacer(minLength: 0)
                    Button("重试") { installModel(descriptor) }.disabled(isModelOperationPending)
                }
            }
        }
    }

    private func modelSizeLabel(_ descriptor: MLXModelDescriptor, entry: MLXModelInventory.Entry?) -> String {
        let bytes = entry?.bytesOnDisk ?? 0
        if entry?.isInstalled == true {
            return "已安装 · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        }
        let download = descriptor.downloadBytes.map {
            "下载约 \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))"
        } ?? "尚未安装"
        return bytes > 0 ? "\(download) · 缓存 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))" : download
    }

    private func refreshModelInventory() async {
        let entries = await Task.detached(priority: .utility) {
            let inventory = MLXModelInventory()
            return Dictionary(uniqueKeysWithValues: MLXModelCatalog.all.map { ($0.repoID, inventory.entry(for: $0)) })
        }.value
        modelInventory = entries
    }

    private func refreshEnginePreferences() {
        let prefs = Preferences.shared
        chineseEngine = prefs.chineseEngine
        englishEngine = prefs.englishEngine
        mixedEngine = prefs.mixedEngine
        activeEngines = prefs.activeEngines
        qwen3ModelRepoID = prefs.qwen3ModelRepoID
    }

    private func observeModelInventory() async {
        await refreshModelInventory()
        while !Task.isCancelled {
            let state = await MLXModelStore.shared.state
            if state != modelStoreState {
                modelStoreState = state
                await refreshModelInventory()
            }
            switch state {
            case .ready(let repoID), .failed(let repoID, _):
                if requestedModelRepoID == repoID { requestedModelRepoID = nil }
            default: break
            }
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
        }
    }

    private func installModel(_ descriptor: MLXModelDescriptor) {
        modelManagementError = ""
        requestedModelRepoID = descriptor.repoID
        MLXModelStore.shared.warmup(descriptor)
    }

    private func selectModel(_ descriptor: MLXModelDescriptor) {
        qwen3ModelRepoID = descriptor.repoID
        Preferences.shared.qwen3ModelRepoID = descriptor.repoID
        installModel(descriptor)
        NotificationCenter.default.post(name: .doushaEngineRoutingChanged, object: nil)
    }

    private func uninstallModel(_ descriptor: MLXModelDescriptor) {
        modelManagementError = ""
        uninstallingModelRepoID = descriptor.repoID
        Task {
            do { try await MLXModelInventory().uninstall(descriptor) }
            catch { modelManagementError = error.localizedDescription }
            await refreshModelInventory()
            uninstallingModelRepoID = nil
        }
    }

    // MARK: - 个性词库

    private var glossaryPane: some View {
        Form {
            Section {
                Toggle(isOn: $glossaryEnabled) {
                    Text("启用个性词库")
                    Text("顿号、逗号或换行分隔，下次录音生效")
                }
                .onChange(of: glossaryEnabled) { _, newValue in
                    Preferences.shared.glossaryEnabled = newValue
                }
                // Parse without rewriting the draft so the insertion point stays put.
                settingsEditor("个性词库", text: $glossaryText,
                               placeholder: "输入关键词、专业术语…\n示例：布迪厄、哈贝马斯、福柯")
                    .onChange(of: glossaryText) { _, newValue in
                        Preferences.shared.glossaryTerms = GlossaryText.parse(newValue)
                    }
                    .disabled(!glossaryEnabled)
                LabeledContent("术语数量", value: "共 \(GlossaryText.parse(glossaryText).count) 个术语")
            } header: {
                HStack {
                    Text("个性词库")
                    settingsHelp("用顿号、逗号或换行分隔术语，下一次录音生效。",
                                 details: "把常用术语、专有名词加进词库，用顿号、逗号或换行分隔；识别时会优先往这些词上靠，提高准确率。对豆包和 Soniox 引擎都生效，下一次录音起作用。Soniox 用词表（terms）偏置，效果通常更明显。")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 智能增强

    private var enhancePane: some View {
        Form {
            Section {
                Picker(selection: $quoteStyle) {
                    Text("中文用「」").tag(TranscriptCorrector.QuoteStyle.corner)
                    Text("中文用“”").tag(TranscriptCorrector.QuoteStyle.curly)
                    Text("不处理").tag(TranscriptCorrector.QuoteStyle.off)
                } label: {
                    Text("引号")
                    Text("将听写中的直引号配对成规范引号")
                }
                .pickerStyle(.menu)
                .onChange(of: quoteStyle) { _, newValue in
                    Preferences.shared.quoteStyle = newValue
                }
            } header: {
                HStack {
                    Text("文本格式")
                    settingsHelp("将听写中的直引号配对成规范引号。",
                                 details: "把听写出来的直引号配对成规范引号。英文始终用 “ ”，撇号写成 don’t；这项只决定中文语境用哪套。")
                }
            }

            Section {
                Toggle(isOn: $llmEnabled) {
                    Text("启用润色")
                    Text("通过兼容 OpenAI 的接口清理听写结果")
                }
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
                            .accessibilityLabel("润色 API 密钥")
                        Button("清除", role: .destructive) { apiKey = "" }
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
                    Button("保存并测试") { saveAndTestLLM() }
                        .disabled(isTesting || apiKey.isEmpty || baseURL.isEmpty || model.isEmpty)
                }
                if isTesting || !status.isEmpty {
                    statusLabel(isTesting ? "测试中…" : status,
                                isError: statusIsError, isProgress: isTesting)
                }
            } header: {
                HStack {
                    Text("润色")
                    settingsHelp("使用兼容 OpenAI 的接口，按润色规则清理听写结果。",
                                 details: "使用任意兼容 OpenAI 的对话补全接口来清理听写结果。默认仅修正明显的识别错误；可在下方自定义润色规则。")
                }
            }

            Section {
                settingsEditor("润色提示词", text: $llmSystemPrompt,
                               placeholder: "输入润色规则…\n留空则使用默认规则。")
                    .disableAutocorrection(true)
                LabeledContent {
                    Text(llmSystemPrompt == savedLLMSystemPrompt ? "已保存" : "未保存")
                } label: {
                    Text("保存状态")
                    Text("保存后生效；留空使用默认规则")
                }
                HStack {
                    Button("恢复默认", role: .destructive) { llmSystemPrompt = TextRefiner.defaultSystemPrompt }
                        .disabled(llmSystemPrompt == TextRefiner.defaultSystemPrompt)
                    Spacer()
                    Button("保存提示词") { saveLLMPrompt() }
                        .disabled(llmSystemPrompt == savedLLMSystemPrompt)
                }
            } header: {
                HStack {
                    Text("润色提示词")
                    settingsHelp("保存后用于后续润色，留空则使用默认规则。",
                                 details: "自定义提示词会完整替换默认规则，可允许清理重复、修复断句或轻度润色。建议要求模型只输出处理后的正文。修改后点击「保存提示词」，后续润色请求生效；留空则使用默认规则。")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 统计

    private var statisticsPane: some View {
        Form {
            Section("概览") {
                if stats.totals.dictations == 0 {
                    Text("暂无统计，完成一次听写后开始累计。")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("听写次数", value: stats.totals.dictations.formatted())
                    LabeledContent("总时长", value: Duration.seconds(stats.totals.audioSeconds)
                        .formatted(.time(pattern: .hourMinuteSecond)))
                    LabeledContent("总字数", value: stats.totals.characters.formatted())
                    LabeledContent("平均速度（字/分钟）", value: stats.charactersPerMinute
                        .formatted(.number.precision(.fractionLength(0))))
                }
            }
            if stats.totals.dictations > 0 {
                Section("最近 7 天") {
                    Chart(stats.recentDays()) { day in
                        BarMark(x: .value("日期", day.date, unit: .day),
                                y: .value("字数", day.counts.characters))
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day)) {
                            AxisValueLabel(format: .dateTime.month().day())
                        }
                    }
                    .chartYAxisLabel("字")
                    .frame(height: 140)
                }
                Section("常用应用") {
                    ForEach(Array(stats.apps.sorted {
                        $0.value.characters == $1.value.characters
                            ? $0.key < $1.key : $0.value.characters > $1.value.characters
                    }.prefix(5)), id: \.key) { bundleID, app in
                        LabeledContent {
                            Text("\(app.dictations) 次 · \(app.characters) 字")
                        } label: {
                            HStack {
                                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                        .resizable().frame(width: 20, height: 20)
                                } else {
                                    Image(systemName: "app").frame(width: 20, height: 20)
                                }
                                Text(app.name)
                            }
                        }
                    }
                }
                Section {
                    Button("重置统计…", role: .destructive) { confirmingStatsReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { stats = statsStore.load() }
        .onReceive(NotificationCenter.default.publisher(for: .doushaStatsChanged)) { _ in
            stats = statsStore.load()
        }
    }

    // MARK: - 权限

    private var permissionsPane: some View {
        Form {
            Section {
                permissionRow("麦克风", granted: microphoneStatus == .authorized,
                              notDetermined: microphoneStatus == .notDetermined,
                              privacyPane: "Privacy_Microphone", request: actions.requestMicrophone)
                permissionRow("辅助功能", granted: accessibilityGranted, notDetermined: false,
                              privacyPane: "Privacy_Accessibility", request: {})
                permissionRow("语音识别", subtitle: "仅 Apple 听写需要", granted: speechStatus == .authorized,
                              notDetermined: speechStatus == .notDetermined,
                              privacyPane: "Privacy_SpeechRecognition", request: actions.requestSpeechRecognition)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func permissionRow(_ title: String, subtitle: String? = nil, granted: Bool,
                               notDetermined: Bool, privacyPane: String,
                               request: @escaping @MainActor () async -> Void) -> some View {
        LabeledContent {
            HStack {
                statusLabel(granted ? "已授权" : (notDetermined ? "未请求" : "未授权"), isError: !granted)
                Button(notDetermined ? "请求" : "打开系统设置") {
                    if notDetermined {
                        Task {
                            await request()
                            refreshPermissions()
                        }
                    } else {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?\(privacyPane)")!)
                    }
                }
            }
        } label: {
            Text(title)
            if let subtitle { Text(subtitle) }
        }
    }

    private func refreshPermissions() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        speechStatus = SFSpeechRecognizer.authorizationStatus()
        accessibilityGranted = AXIsProcessTrusted()
    }

    // MARK: - 历史记录

    private var historyPane: some View {
        Form {
            Section {
                Stepper(value: $historyLimit, in: 1...50) {
                    Text("保留最近 \(historyLimit) 条录音")
                    Text("本机缓存原始录音与文本，超出后删最旧的")
                }
                .onChange(of: historyLimit) { _, newValue in
                    Preferences.shared.historyLimit = newValue
                    history.prune(limit: newValue)
                }
            } header: {
                Text("存储")
            }
            Section("最近录音") {
                if historyEntries.isEmpty {
                    Text("暂无录音").foregroundStyle(.secondary)
                }
                ForEach(historyEntries) { entry in
                    historyRow(entry)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            historyEntries = history.entries()
            canRetranscribeNow = actions.canRetranscribe()
        }
        .onReceive(NotificationCenter.default.publisher(for: .doushaHistoryChanged)
            .receive(on: DispatchQueue.main)) { _ in
            historyEntries = history.entries()
            canRetranscribeNow = actions.canRetranscribe()
        }
        // The history-changed notification fires while the controller is still
        // .transcribing (the save happens before the final transition), so a
        // render at that moment bakes in disabled buttons that nothing would
        // ever refresh. Re-read the gate on every controller status change.
        .onReceive(NotificationCenter.default.publisher(for: .doushaRecordingStatusChanged)
            .receive(on: DispatchQueue.main)) { _ in
            canRetranscribeNow = actions.canRetranscribe()
        }
    }

    private func historyRow(_ entry: RecordingHistoryEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.transcript.isEmpty ? "（无文本）" : entry.transcript)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(entry.transcript.isEmpty ? .secondary : .primary)
                    if let error = entry.error {
                        statusLabel("转录失败：\(error)", isError: true, symbolOnly: true)
                    }
                }
                Text(historyMetadata(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新转录") { actions.retranscribe(entry.id) }
                .disabled(!canRetranscribeNow)
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(entry.transcript, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制文本")
            .accessibilityLabel("复制文本")
            .disabled(entry.transcript.isEmpty)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([history.wavURL(id: entry.id)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
            .accessibilityLabel("在 Finder 中显示")
        }
    }

    private func historyMetadata(_ entry: RecordingHistoryEntry) -> String {
        var components = [entry.date.formatted(.dateTime.month().day().hour().minute()),
                          Self.durationLabel(entry.duration)]
        if !entry.engine.isEmpty { components.append(entry.engine) }
        return components.joined(separator: " · ")
    }

    private static func durationLabel(_ d: TimeInterval) -> String {
        let s = Int(d.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
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

    // MARK: - Shared native presentation

    /// All result/progress text stays secondary; only the status symbol is coloured.
    private func statusLabel(_ message: String, isError: Bool = false,
                             isProgress: Bool = false, symbolOnly: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? .orange : .green)
            }
            if !symbolOnly {
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(message)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }

    /// Both editors share the form row's surface and an appearance-aware hairline.
    private func settingsEditor(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(height: 200)
                .accessibilityLabel(title)
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The popover's presentation lives here too, so helper fragments have no state.
    private func settingsHelp(_ summary: String, details: String) -> some View {
        Button { presentedHelp = details } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("更多说明：\(summary)")
        .help(details)
        .popover(isPresented: Binding(
            get: { presentedHelp == details },
            set: { if !$0 { presentedHelp = nil } }
        )) {
            Text(details)
                .font(.body)
                .padding()
                .frame(width: 340)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func saveLLMPrompt() {
        Preferences.shared.llmSystemPrompt = llmSystemPrompt
        llmSystemPrompt = Preferences.shared.llmSystemPrompt
        savedLLMSystemPrompt = llmSystemPrompt
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
        let refiner = TextRefiner(baseURL: baseURL, apiKey: apiKey, model: model,
                                  systemPrompt: Preferences.shared.llmSystemPrompt)
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
/// Mirrors `CancelKeyRecorder` but listens to flagsChanged instead of keyDown.
final class HotkeyRecorder: @unchecked Sendable {
    private let tap = EventTap()
    private var onCaptured: (@MainActor (UInt16) -> Void)?

    func start(onCaptured: @escaping @MainActor (UInt16) -> Void) {
        guard !tap.isInstalled else { return }
        self.onCaptured = onCaptured

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        if !tap.install(mask: mask, label: "HotkeyRecorder", handler: { [weak self] type, event in
            self?.handle(type: type, event: event) ?? Unmanaged.passUnretained(event)
        }) {
            self.onCaptured = nil
        }
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
        tap.teardown()
        onCaptured = nil
    }
}

extension Notification.Name {
    static let doushaHotkeyConfigChanged = Notification.Name("DoushaHotkeyConfigChanged")
    static let doushaLLMEnabledChanged = Notification.Name("DoushaLLMEnabledChanged")
    /// Posted when the engine routing slots / primary language change in Settings,
    /// so the menu bar can rebuild to reflect the new active set / primary.
    static let doushaEngineRoutingChanged = Notification.Name("DoushaEngineRoutingChanged")
    /// Posted (main thread) on every RecordingController status transition, so
    /// the settings history pane can refresh its retranscribe-enabled state.
    static let doushaRecordingStatusChanged = Notification.Name("DoushaRecordingStatusChanged")
}
