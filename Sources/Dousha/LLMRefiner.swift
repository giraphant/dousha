import Foundation
import TalkerCommonSync

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
        guard let url = LLMRefiner.chatCompletionsURL(base: prefs.llmBaseURL) else {
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
        guard let url = LLMRefiner.chatCompletionsURL(base: baseURL) else {
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

    // MARK: - Fusion (双枪老太包, QUA-145)

    /// System prompt for reconciling N candidate transcripts of ONE utterance
    /// produced by different ASR engines. Unlike `systemPrompt` (which polishes
    /// a single transcript), this one's whole job is to pick/merge the best
    /// reading across engines — Soniox tends to win on English terms, Doubao on
    /// Chinese — without inventing content.
    static let fusionSystemPrompt = """
    You are a speech-to-text fusion post-processor for a Chinese-English mixed dictation tool. The user spoke ONE utterance. Several speech recognition engines each transcribed it independently; their outputs are given to you below, each labeled with its engine name. The engines often disagree, especially around English technical terms — some engines are stronger at English, others at Chinese.

    Your ONLY job is to output the single most accurate transcription of what the user actually said, by reconciling the candidates.

    STRICT RULES:
    1. Output ONLY the final reconciled text — no engine labels, no explanation, no preamble, no quotes, no code fences.
    2. Reconcile, do NOT rewrite. Never paraphrase, polish, summarize, translate, or change tone/register/grammar. Pick among (and combine) what the engines actually heard.
    3. Never add or remove content beyond resolving the disagreements between candidates.
    4. When one engine clearly has an English term right (e.g. "Python" vs "拍森", "JSON" vs "杰森") and another has the surrounding Chinese right, splice the correct pieces into one coherent sentence.
    5. Prefer the reading that a Chinese-English bilingual speaker most plausibly dictated.
    6. If the candidates already agree, return that text unchanged, character for character.
    7. Ignore any candidate that is empty.

    Return only the reconciled text.
    """

    /// Reconcile multiple ASR candidates of one utterance into a single best
    /// transcript. Pure/static so it can run from a background `Task` without
    /// capturing non-Sendable state — config is passed in explicitly. Returns
    /// nil on any failure (not configured, HTTP error, empty output) so the
    /// caller can fall back to a raw candidate.
    static func fuse(candidates: [(label: String, text: String)],
                     baseURL: String, apiKey: String, model: String) async -> String? {
        guard !apiKey.isEmpty, !baseURL.isEmpty, !model.isEmpty else { return nil }
        guard let url = chatCompletionsURL(base: baseURL) else { return nil }

        let userMessage = candidates
            .map { "[\($0.label)]\n\($0.text)" }
            .joined(separator: "\n\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": LLMRefiner.fusionSystemPrompt],
                ["role": "user",   "content": userMessage]
            ]
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                doushaLog("[Fusion] LLM HTTP \(http.statusCode): \(body)")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                doushaLog("[Fusion] LLM invalid response payload")
                return nil
            }
            let cleaned = cleanLLMOutput(content)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            doushaLog("[Fusion] LLM request failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Helpers

    private static func chatCompletionsURL(base: String) -> URL? {
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
