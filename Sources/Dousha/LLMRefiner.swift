import Foundation

final class LLMRefiner {
    private let prefs = Preferences.shared

    var isConfigured: Bool {
        let p = Preferences.shared
        return !p.llmAPIKey.isEmpty && !p.llmBaseURL.isEmpty && !p.llmModel.isEmpty
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

    /// Call the configured chat-completions endpoint. On any failure the original text is returned via the success path
    /// (refinement is best-effort — we never want to lose the user's dictation).
    func refine(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard isConfigured else {
            completion(.success(text))
            return
        }
        guard let url = chatCompletionsURL(base: prefs.llmBaseURL) else {
            completion(.failure(NSError(domain: "LLMRefiner", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Invalid base URL"])))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(prefs.llmAPIKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": prefs.llmModel,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": LLMRefiner.systemPrompt],
                ["role": "user",   "content": text]
            ]
        ])

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(.failure(NSError(domain: "LLMRefiner", code: http.statusCode,
                                            userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])))
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                completion(.failure(NSError(domain: "LLMRefiner", code: -2,
                                            userInfo: [NSLocalizedDescriptionKey: "Invalid response payload"])))
                return
            }
            let cleaned = LLMRefiner.cleanLLMOutput(content)
            completion(.success(cleaned.isEmpty ? text : cleaned))
        }.resume()
    }

    func test(baseURL: String, apiKey: String, model: String,
              completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = chatCompletionsURL(base: baseURL) else {
            completion(.failure(NSError(domain: "LLMRefiner", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Invalid base URL"])))
            return
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
                ["role": "system", "content": LLMRefiner.systemPrompt],
                ["role": "user",   "content": "ping"]
            ]
        ])

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(.failure(NSError(domain: "LLMRefiner", code: http.statusCode,
                                            userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])))
                return
            }
            completion(.success("OK"))
        }.resume()
    }

    // MARK: - Helpers

    private func chatCompletionsURL(base: String) -> URL? {
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
        // Strip surrounding quotes / code fences if the model insisted on them.
        if s.hasPrefix("```") {
            if let end = s.range(of: "```", options: .backwards), end.lowerBound > s.startIndex {
                let firstNL = s.firstIndex(of: "\n") ?? s.startIndex
                s = String(s[s.index(after: firstNL)..<end.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) ||
           (s.hasPrefix("“") && s.hasSuffix("”")) ||
           (s.hasPrefix("「") && s.hasSuffix("」")) {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }
}
