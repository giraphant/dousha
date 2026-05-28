import Cocoa
import CoreGraphics
import SwiftUI
import TalkerCommonSync

enum SettingsWindowFactory {
    static func create(llmRefiner: LLMRefiner) -> NSWindow {
        let view = SettingsView(llmRefiner: llmRefiner)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "豆沙 — 设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 560))
        return window
    }
}

struct SettingsView: View {
    let llmRefiner: LLMRefiner

    @State private var hotkeyKeyCode: UInt16 = Preferences.shared.hotkey.keyCode
    @State private var hotkeyMode: HotkeyMode = Preferences.shared.hotkey.mode
    @State private var isRecordingHotkey: Bool = false
    private let recorder = HotkeyRecorder()

    @State private var cancelHotkey: CancelHotkeyConfig = Preferences.shared.cancelHotkey
    @State private var isRecordingCancelHotkey: Bool = false
    private let cancelRecorder = CancelKeyRecorder()

    @State private var smartRetranscribeEnabled: Bool = Preferences.shared.smartRetranscribeEnabled

    @State private var baseURL: String = Preferences.shared.llmBaseURL
    @State private var apiKey:  String = Preferences.shared.llmAPIKey
    @State private var model:   String = Preferences.shared.llmModel

    @State private var status: String = ""
    @State private var statusIsError: Bool = false
    @State private var isTesting: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 热键
            Text("热键")
                .font(.title3).bold()
            Text("选择一个修饰键来触发听写。长按说话：按住时录音；切换：每次按下开始/停止。")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                field(label: "触发键") {
                    HStack(spacing: 8) {
                        Text(HotkeyMonitor.displayName(forKeyCode: hotkeyKeyCode))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12)))
                        Button(isRecordingHotkey ? "按下修饰键…" : "录制") {
                            toggleRecording()
                        }
                    }
                }
                field(label: "模式") {
                    Picker("", selection: $hotkeyMode) {
                        Text("长按说话").tag(HotkeyMode.pushToTalk)
                        Text("切换").tag(HotkeyMode.toggle)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .onChange(of: hotkeyMode) { _, newMode in
                        var cfg = Preferences.shared.hotkey
                        cfg = HotkeyConfig(keyCode: cfg.keyCode, mode: newMode)
                        Preferences.shared.hotkey = cfg
                        NotificationCenter.default.post(name: .doushaHotkeyConfigChanged, object: nil)
                    }
                }
                field(label: "取消键") {
                    HStack(spacing: 8) {
                        Text(cancelHotkey.displayName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12)))
                        Button(isRecordingCancelHotkey ? "按任意键…" : "录制") {
                            toggleCancelHotkeyRecording()
                        }
                        Button("关闭") {
                            cancelHotkey = .disabled
                            Preferences.shared.cancelHotkey = .disabled
                            NotificationCenter.default.post(name: .doushaCancelHotkeyConfigChanged, object: nil)
                        }
                        .disabled(!cancelHotkey.isEnabled)
                    }
                }
            }
            Text("取消会丢弃当前录音且不转写。仅在录音时生效，其余情况下按键正常透传。")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 4)

            Text("转写")
                .font(.title3).bold()

            VStack(alignment: .leading, spacing: 10) {
                field(label: "智能重录") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("检测到可能漏转写时，自动用上一段录音重新转写", isOn: $smartRetranscribeEnabled)
                            .onChange(of: smartRetranscribeEnabled) { _, newValue in
                                Preferences.shared.smartRetranscribeEnabled = newValue
                            }
                        Text("Beta 测试中，默认关闭")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            Text("关闭后，豆沙会直接使用首次转写结果；菜单里的「重新转写」仍可手动使用。")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 4)

            Text("润色")
                .font(.title3).bold()
            Text("使用任意兼容 OpenAI 的对话补全接口来清理听写结果。模型只会修正明显的识别错误，不会改写内容。")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                field(label: "API 地址") {
                    TextField("https://api.openai.com/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }
                field(label: "API 密钥") {
                    HStack(spacing: 6) {
                        SecureField("sk-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                        Button("清除") { apiKey = "" }
                            .help("删除已保存的 API 密钥")
                    }
                }
                field(label: "模型") {
                    TextField("gpt-4o-mini", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }
            }

            if !status.isEmpty {
                Text(status)
                    .font(.callout)
                    .foregroundColor(statusIsError ? .red : .green)
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
        }
        .padding(20)
        .frame(width: 520, alignment: .topLeading)
    }

    @ViewBuilder
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .frame(width: 110, alignment: .trailing)
                .foregroundColor(.secondary)
            content()
        }
    }

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
        status = "已保存。"
        statusIsError = false
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
}
