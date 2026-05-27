import Cocoa
import CoreGraphics
import SwiftUI

enum SettingsWindowFactory {
    static func create(llmRefiner: LLMRefiner) -> NSWindow {
        let view = SettingsView(llmRefiner: llmRefiner)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Dousha — Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 480))
        return window
    }
}

struct SettingsView: View {
    let llmRefiner: LLMRefiner

    @State private var hotkeyKeyCode: UInt16 = Preferences.shared.hotkey.keyCode
    @State private var hotkeyMode: HotkeyMode = Preferences.shared.hotkey.mode
    @State private var isRecordingHotkey: Bool = false
    private let recorder = HotkeyRecorder()

    @State private var baseURL: String = Preferences.shared.llmBaseURL
    @State private var apiKey:  String = Preferences.shared.llmAPIKey
    @State private var model:   String = Preferences.shared.llmModel

    @State private var status: String = ""
    @State private var statusIsError: Bool = false
    @State private var isTesting: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Hotkey section
            Text("Hotkey")
                .font(.title3).bold()
            Text("Choose a modifier key to trigger dictation. Push-to-Talk records while held; Toggle starts/stops with each press.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                field(label: "Trigger key") {
                    HStack(spacing: 8) {
                        Text(HotkeyMonitor.displayName(forKeyCode: hotkeyKeyCode))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.12)))
                        Button(isRecordingHotkey ? "Press a modifier key…" : "Record") {
                            toggleRecording()
                        }
                    }
                }
                field(label: "Mode") {
                    Picker("", selection: $hotkeyMode) {
                        Text("Push to Talk").tag(HotkeyMode.pushToTalk)
                        Text("Toggle").tag(HotkeyMode.toggle)
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
            }

            Divider().padding(.vertical, 4)

            Text("LLM Refinement")
                .font(.title3).bold()
            Text("Use any OpenAI-compatible chat completions endpoint to clean up dictation results. The model is asked to fix only obvious recognition errors and never to rewrite content.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                field(label: "API Base URL") {
                    TextField("https://api.openai.com/v1", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }
                field(label: "API Key") {
                    HStack(spacing: 6) {
                        SecureField("sk-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                        Button("Clear") { apiKey = "" }
                            .help("Remove the saved API key")
                    }
                }
                field(label: "Model") {
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
                Button(isTesting ? "Testing…" : "Test") { test() }
                    .disabled(isTesting || apiKey.isEmpty || baseURL.isEmpty || model.isEmpty)
                Spacer()
                Button("Save") { save() }
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
        status = "Testing connection…"
        statusIsError = false
        llmRefiner.test(baseURL: baseURL, apiKey: apiKey, model: model) { result in
            DispatchQueue.main.async {
                isTesting = false
                switch result {
                case .success:
                    status = "Connection OK."
                    statusIsError = false
                case .failure(let err):
                    status = "Failed: \(err.localizedDescription)"
                    statusIsError = true
                }
            }
        }
    }

    private func save() {
        Preferences.shared.llmBaseURL = baseURL
        Preferences.shared.llmAPIKey  = apiKey
        Preferences.shared.llmModel   = model
        status = "Saved."
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
