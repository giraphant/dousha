import Foundation
import TalkerCommonSync

/// Independent, best-effort speech-to-text post-processor. A value type built
/// per-use from Preferences. On any failure `refine` returns nil so the caller
/// keeps the user's raw dictation — refinement must never lose text.
struct TextRefiner: Sendable {
    let baseURL: String
    let apiKey: String
    let model: String

    var isConfigured: Bool {
        !apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty
    }

    static let systemPrompt = """
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
    func refine(_ text: String) async -> String? {
        guard isConfigured, let url = Self.chatCompletionsURL(base: baseURL) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user",   "content": text]
            ]
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                doushaLog("[TextRefiner] HTTP \(http.statusCode)")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                doushaLog("[TextRefiner] invalid response payload")
                return nil
            }
            let cleaned = Self.cleanLLMOutput(content)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            doushaLog("[TextRefiner] request failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Deferred mode: returns the original text immediately for the caller to
    /// paste now, and refines in the background. `completion` fires on the main
    /// queue with the polished text ONLY when it differs from the original
    /// (callers use it to silently update the clipboard). If refinement fails or
    /// is a no-op, completion never fires.
    @discardableResult
    func refineLater(_ text: String, completion: @escaping @Sendable (String) -> Void) -> String {
        Task {
            guard let refined = await refine(text), refined != text else { return }
            DispatchQueue.main.async { completion(refined) }
        }
        return text
    }

    /// Settings "test connection" probe. Sends a trivial prompt; success means
    /// the endpoint/key/model are usable.
    func test() async -> Result<String, Error> {
        guard let url = Self.chatCompletionsURL(base: baseURL) else {
            return .failure(NSError(domain: "TextRefiner", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Invalid base URL"]))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user",   "content": "ping"]
            ]
        ])
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .failure(NSError(domain: "TextRefiner", code: http.statusCode,
                                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"]))
            }
            return .success("OK")
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Helpers (pure, unit-tested)

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
