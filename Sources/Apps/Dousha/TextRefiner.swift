import Foundation
import ConcurrencySupport

/// Independent, best-effort speech-to-text post-processor. A value type built
/// per-use from Preferences. On any failure `refine` returns nil so the caller
/// keeps the user's raw dictation — refinement must never lose text.
struct TextRefiner: Sendable {
    let baseURL: String
    let apiKey: String
    let model: String
    let systemPrompt: String

    init(baseURL: String, apiKey: String, model: String,
         systemPrompt: String = TextRefiner.defaultSystemPrompt) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.systemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultSystemPrompt : systemPrompt
    }

    private var promptSource: String {
        systemPrompt == Self.defaultSystemPrompt ? "default" : "custom"
    }

    var isConfigured: Bool {
        !apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty
    }

    static let defaultSystemPrompt = """
    You are a speech-to-text post-processor for a Chinese-English mixed dictation tool. Your ONLY job is to fix obvious speech recognition errors. Be extremely conservative — when in doubt, return the input unchanged.

    STRICT RULES (never break these):
    1. NEVER rewrite, paraphrase, polish, summarize, or "improve" the text in any way.
    2. NEVER add or remove content. Do not insert or delete words, phrases, or sentences.
    3. NEVER change the language, tone, register, punctuation style, or grammar.
    4. NEVER explain, annotate, comment, apologize, or wrap the output in quotes / code fences.
    5. Output ONLY the corrected text — nothing else, no preamble, no trailing notes.
    6. If the input already looks correct, return it EXACTLY as-is, character for character.

    WHAT TO FIX (only these narrow cases):
    - English technical terms mistakenly transcribed as Chinese homophones, e.g.:
        配森 / 拍森 → Python
        杰森 → JSON
        利可特 → React
        个特 → Git
        阿派 → API
        多课 → Docker
        艾克斯 → x / X
    - Obvious Chinese homophone errors that clearly change the meaning of a sentence.
    - Obvious word-boundary mistakes that produce nonsense.

    WHAT TO LEAVE ALONE:
    - Anything ambiguous.
    - Style, word choice, or punctuation preferences.
    - Anything that "could be slightly better."
    - Repetition, filler words, or hesitations the user dictated on purpose.

    Return only the (possibly identical) corrected text.
    """

    /// Immediate mode: await the LLM and return polished text, or nil on any
    /// failure (not configured, HTTP error, empty output).
    func refine(_ text: String, traceId: String = UUID().uuidString,
                mode: String = "immediate") async -> String? {
        let started = ProcessInfo.processInfo.systemUptime
        func elapsedMs() -> Int { Int((ProcessInfo.processInfo.systemUptime - started) * 1000) }
        let trace = "traceId=\(traceId) mode=\(mode)"
        guard isConfigured else {
            doushaLog("[TextRefiner] skipped \(trace) reason=not_configured hasBaseURL=\(!baseURL.isEmpty) hasAPIKey=\(!apiKey.isEmpty) hasModel=\(!model.isEmpty)")
            return nil
        }
        guard let req = makeRequest(for: text, timeout: 20) else {
            doushaLog("[TextRefiner] skipped \(trace) reason=invalid_url")
            return nil
        }

        doushaLog("[TextRefiner] request started \(trace) model=\(model) inputLen=\(text.count) timeoutSeconds=\(Int(req.timeoutInterval)) promptSource=\(promptSource) promptLen=\(systemPrompt.count)")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            doushaLog("[TextRefiner] response received \(trace) status=\(status) bytes=\(data.count) elapsedMs=\(elapsedMs())")
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                doushaLog("[TextRefiner] HTTP \(http.statusCode) \(trace) elapsedMs=\(elapsedMs())")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                doushaLog("[TextRefiner] invalid response payload \(trace) reason=invalid_json elapsedMs=\(elapsedMs())")
                return nil
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                doushaLog("[TextRefiner] invalid response payload \(trace) reason=missing_content elapsedMs=\(elapsedMs())")
                return nil
            }
            let cleaned = Self.cleanLLMOutput(content)
            let outcome = cleaned.isEmpty ? "empty_output" : cleaned == text ? "unchanged" : "changed"
            let finishReason = first["finish_reason"] as? String ?? "unknown"
            doushaLog("[TextRefiner] completed \(trace) outcome=\(outcome) inputLen=\(text.count) rawOutputLen=\(content.count) outputLen=\(cleaned.count) finishReason=\(finishReason) elapsedMs=\(elapsedMs())")
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            let nsError = error as NSError
            let reason = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
                ? "timeout" : "transport_error"
            doushaLog("[TextRefiner] request failed: \(error.localizedDescription) \(trace) reason=\(reason) errorDomain=\(nsError.domain) errorCode=\(nsError.code) elapsedMs=\(elapsedMs())")
            return nil
        }
    }

    /// Deferred mode: returns the original text immediately for the caller to
    /// paste now, and refines in the background. `completion` fires on the main
    /// queue with the polished text ONLY when it differs from the original
    /// (callers use it to silently update the clipboard). If refinement fails or
    /// is a no-op, completion never fires.
    @discardableResult
    func refineLater(_ text: String, traceId: String = UUID().uuidString,
                     completion: @escaping @Sendable (String) -> Void) -> String {
        doushaLog("[TextRefiner] deferred queued traceId=\(traceId) inputLen=\(text.count)")
        Task {
            guard let refined = await refine(text, traceId: traceId, mode: "deferred") else {
                doushaLog("[TextRefiner] deferred clipboard skipped traceId=\(traceId) reason=no_result")
                return
            }
            guard refined != text else {
                doushaLog("[TextRefiner] deferred clipboard skipped traceId=\(traceId) reason=unchanged")
                return
            }
            DispatchQueue.main.async { completion(refined) }
        }
        return text
    }

    /// Settings "test connection" probe. Sends a trivial prompt; success means
    /// the endpoint/key/model are usable.
    func test() async -> Result<String, Error> {
        let traceId = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        func elapsedMs() -> Int { Int((ProcessInfo.processInfo.systemUptime - started) * 1000) }
        let trace = "traceId=\(traceId) mode=connection_test"
        guard let req = makeRequest(for: "ping", timeout: 15) else {
            doushaLog("[TextRefiner] skipped \(trace) reason=invalid_url")
            return .failure(NSError(domain: "TextRefiner", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Invalid base URL"]))
        }
        doushaLog("[TextRefiner] request started \(trace) model=\(model) inputLen=4 timeoutSeconds=\(Int(req.timeoutInterval)) promptSource=\(promptSource) promptLen=\(systemPrompt.count)")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            doushaLog("[TextRefiner] response received \(trace) status=\(status) bytes=\(data.count) elapsedMs=\(elapsedMs())")
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                doushaLog("[TextRefiner] HTTP \(http.statusCode) \(trace) elapsedMs=\(elapsedMs())")
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure(NSError(domain: "TextRefiner", code: http.statusCode,
                                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"]))
            }
            doushaLog("[TextRefiner] completed \(trace) outcome=http_ok elapsedMs=\(elapsedMs())")
            return .success("OK")
        } catch {
            let nsError = error as NSError
            doushaLog("[TextRefiner] request failed: \(error.localizedDescription) \(trace) errorDomain=\(nsError.domain) errorCode=\(nsError.code) elapsedMs=\(elapsedMs())")
            return .failure(error)
        }
    }

    // MARK: - Helpers (pure, unit-tested)

    /// Both dictation and the connection test use the same prompt snapshot.
    /// A custom prompt replaces the default; it is never appended to it.
    func makeRequest(for text: String, timeout: TimeInterval) -> URLRequest? {
        guard let url = Self.chatCompletionsURL(base: baseURL) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": text]
            ]
        ])
        return req
    }

    static func chatCompletionsURL(base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed)
        }
        let stripped = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return URL(string: stripped + "/chat/completions")
    }

    static func cleanLLMOutput(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let end = s.range(of: "```", options: .backwards), end.lowerBound > s.startIndex {
                let firstNL = s.firstIndex(of: "\n") ?? s.startIndex
                s = String(s[s.index(after: firstNL)..<end.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) ||
           (s.hasPrefix("\u{201C}") && s.hasSuffix("\u{201D}")) ||
           (s.hasPrefix("「") && s.hasSuffix("」")) {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }
}
