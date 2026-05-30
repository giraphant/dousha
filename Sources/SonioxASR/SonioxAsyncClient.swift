import Foundation
import TalkerCommonSync
import ASRSupport

/// Pure, `Sendable`, unit-testable parser for the async transcript response.
///
/// The async transcript endpoint returns a JSON object shaped like the
/// real-time batches — a `tokens` array of `{ "text", "translation_status"? }`
/// — but all at once with no `is_final` distinction. We concatenate token text
/// (skipping translation tokens and the `<end>` endpoint marker) to match the
/// real-time parser's output. If no usable tokens are present we fall back to a
/// top-level `text` field.
public struct SonioxAsyncTranscriptParser: Sendable {
    public init() {}

    public func parse(jsonData: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return ""
        }
        return parse(object: obj)
    }

    public func parse(object obj: [String: Any]) -> String {
        if let tokens = obj["tokens"] as? [[String: Any]], !tokens.isEmpty {
            var text = ""
            for token in tokens {
                let status = token["translation_status"] as? String
                if status == "translation" { continue }
                let t = (token["text"] as? String) ?? ""
                if t == "<end>" { continue }
                text += t
            }
            if !text.isEmpty { return text }
        }
        return (obj["text"] as? String) ?? ""
    }
}

/// Drives Soniox's async (batch) REST flow: upload the WAV, create a
/// transcription, poll until done, fetch the transcript, then best-effort clean
/// up the server-side file + transcription. Stateless beyond the API key.
public struct SonioxAsyncClient: Sendable {
    public enum AsyncError: Error, LocalizedError {
        case missingKey
        case http(Int, String)
        case decode(String)
        case transcriptionFailed(String)
        case timeout

        public var errorDescription: String? {
            switch self {
            case .missingKey: return "Soniox API key is missing. Add it in Settings."
            case .http(let code, let body): return "Soniox HTTP \(code): \(body)"
            case .decode(let what): return "Soniox response decode failed: \(what)"
            case .transcriptionFailed(let msg): return "Soniox transcription failed: \(msg)"
            case .timeout: return "Soniox transcription timed out."
            }
        }
    }

    private let apiKey: String
    private let baseURL: String
    private let model: String
    /// Glossary terms for the async `context.terms` (QUA-133). Empty => omitted.
    private let contextTerms: [String]
    /// ISO codes for the async `language_hints` (biases auto-detect). Empty => omitted.
    private let languageHints: [String]
    private let session: URLSession

    /// Max time to wait for the server-side transcription to finish.
    private let pollTimeout: TimeInterval
    /// Delay between status polls.
    private let pollInterval: TimeInterval

    public init(apiKey: String,
                baseURL: String = SonioxConfig.asyncBaseURL,
                model: String = SonioxConfig.asyncModel,
                contextTerms: [String] = [],
                languageHints: [String] = [],
                pollTimeout: TimeInterval = 120,
                pollInterval: TimeInterval = 0.75,
                session: URLSession? = nil) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.contextTerms = contextTerms
        self.languageHints = languageHints
        self.pollTimeout = pollTimeout
        self.pollInterval = pollInterval
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Upload `fileURL`, transcribe it, and return the final text. Cleans up the
    /// server-side file + transcription before returning (best effort).
    public func transcribe(fileURL: URL, traceId: String? = nil) async throws -> String {
        guard !apiKey.isEmpty else { throw AsyncError.missingKey }
        let trace = traceId.map { "traceId=\($0) " } ?? ""

        let fileId = try await uploadFile(fileURL: fileURL)
        doushaLog("[SonioxAsync] \(trace)uploaded file_id=\(fileId)")

        // Install cleanup as soon as the file exists server-side, so a failure
        // creating the transcription doesn't leak the uploaded file. The
        // transcription is deleted too once we know its id. Fire-and-forget so
        // the result isn't blocked on cleanup.
        var transcriptionId: String?
        defer {
            let fid = fileId
            let tid = transcriptionId
            Task { [self] in
                if let tid { await self.deleteResource(path: "/v1/transcriptions/\(tid)") }
                await self.deleteResource(path: "/v1/files/\(fid)")
            }
        }

        let createdId = try await createTranscription(fileId: fileId)
        transcriptionId = createdId
        doushaLog("[SonioxAsync] \(trace)transcription_id=\(createdId)")

        try await pollUntilDone(transcriptionId: createdId, trace: trace)

        let text = try await fetchTranscript(transcriptionId: createdId)
        doushaLog("[SonioxAsync] \(trace)transcript text.len=\(text.count)")
        return text
    }

    // MARK: - Steps

    private func uploadFile(fileURL: URL) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: try url("/v1/files"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: fileURL)
        var body = Data()
        let filename = fileURL.lastPathComponent
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let obj = try await sendJSON(req)
        guard let id = obj["id"] as? String else {
            throw AsyncError.decode("files response missing id")
        }
        return id
    }

    /// Builds the POST /v1/transcriptions JSON body. Pure + public so the
    /// glossary `context.terms` inclusion is unit-testable without HTTP (QUA-133).
    public static func transcriptionRequestBody(model: String, fileId: String, contextTerms: [String], languageHints: [String] = []) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "file_id": fileId
        ]
        if let context = SonioxConfig.contextObject(terms: contextTerms) {
            body["context"] = context
        }
        if !languageHints.isEmpty {
            body["language_hints"] = languageHints
        }
        return body
    }

    private func createTranscription(fileId: String) async throws -> String {
        var req = URLRequest(url: try url("/v1/transcriptions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = SonioxAsyncClient.transcriptionRequestBody(model: model, fileId: fileId, contextTerms: contextTerms, languageHints: languageHints)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let obj = try await sendJSON(req)
        guard let id = obj["id"] as? String else {
            throw AsyncError.decode("transcriptions response missing id")
        }
        return id
    }

    private func pollUntilDone(transcriptionId: String, trace: String) async throws {
        let deadline = Date().addingTimeInterval(pollTimeout)
        while Date() < deadline {
            var req = URLRequest(url: try url("/v1/transcriptions/\(transcriptionId)"))
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let obj = try await sendJSON(req)
            let status = (obj["status"] as? String) ?? ""
            switch status {
            case "completed":
                return
            case "error":
                let msg = (obj["error_message"] as? String) ?? "unknown error"
                throw AsyncError.transcriptionFailed(msg)
            default:
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
        }
        throw AsyncError.timeout
    }

    private func fetchTranscript(transcriptionId: String) async throws -> String {
        var req = URLRequest(url: try url("/v1/transcriptions/\(transcriptionId)/transcript"))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        try Self.checkStatus(data: data, response: response)
        return SonioxAsyncTranscriptParser().parse(jsonData: data)
    }

    private func deleteResource(path: String) async {
        guard let u = try? url(path) else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: req)
    }

    // MARK: - Helpers

    private func url(_ path: String) throws -> URL {
        guard let u = URL(string: baseURL + path) else { throw URLError(.badURL) }
        return u
    }

    private func sendJSON(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: req)
        try Self.checkStatus(data: data, response: response)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AsyncError.decode("expected JSON object")
        }
        return obj
    }

    private static func checkStatus(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AsyncError.http(http.statusCode, body)
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}
