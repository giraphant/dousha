import Cocoa
import SwiftUI

enum SettingsWindowFactory {
    static func create(llmRefiner: LLMRefiner) -> NSWindow {
        let view = SettingsView(llmRefiner: llmRefiner)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Dousha — LLM Refinement"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 320))
        return window
    }
}

struct SettingsView: View {
    let llmRefiner: LLMRefiner

    @State private var baseURL: String = Preferences.shared.llmBaseURL
    @State private var apiKey:  String = Preferences.shared.llmAPIKey
    @State private var model:   String = Preferences.shared.llmModel

    @State private var status: String = ""
    @State private var statusIsError: Bool = false
    @State private var isTesting: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
}
