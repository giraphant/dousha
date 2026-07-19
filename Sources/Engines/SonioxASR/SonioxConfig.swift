import Foundation

/// How Soniox transcribes a recording.
/// - `realtime`: stream PCM live over the WebSocket (`stt-rt-v4`), low latency.
/// - `async`: capture to a WAV, then upload the whole file to the async REST
///   API (`stt-async-v4`) on stop — higher accuracy, no live feedback.
public enum SonioxMode: String, Sendable, CaseIterable {
    case realtime
    case async
}

/// Soniox real-time STT constants and the first-message config builder.
///
/// The protocol is far simpler than Doubao: raw PCM s16le over a plain
/// WebSocket, no device registration / JWT / Opus / protobuf. The very first
/// WS message is a JSON text frame carrying the API key + audio format; every
/// subsequent frame is binary PCM.
public enum SonioxConfig {
    public static let endpoint = "wss://stt-rt.soniox.com/transcribe-websocket"
    public static let model = "stt-rt-v4"
    public static let sampleRate = 16_000
    public static let channels = 1

    /// Async (batch) REST API. Higher accuracy than real-time, no live feedback:
    /// the whole WAV is uploaded on stop, transcribed server-side, then polled.
    public static let asyncBaseURL = "https://api.soniox.com"
    public static let asyncModel = "stt-async-v4"

    /// 20ms of int16 mono @16kHz = 320 samples = 640 bytes.
    public static let samplesPerFrame = 320
    public static var bytesPerFrame: Int { samplesPerFrame * MemoryLayout<Int16>.size }

    /// Keepalive cadence during mid-recording silences. The server tears down
    /// idle connections; the JS reference pings every 15s, we use 10s for a
    /// little more margin on long pauses.
    public static let keepaliveIntervalSeconds: TimeInterval = 10.0

    /// Builds Soniox's `context` request object from a glossary term list, or
    /// `nil` when there are no terms (so callers omit the key entirely rather
    /// than sending an empty object). Soniox's `context.terms` is a string array
    /// of domain words used to bias recognition toward proper nouns / jargon
    /// (QUA-133). Terms are expected pre-normalized (trimmed/deduped/capped) by
    /// the caller.
    public static func contextObject(terms: [String]) -> [String: Any]? {
        guard !terms.isEmpty else { return nil }
        return ["terms": terms]
    }

    /// Builds the first-message JSON (a text frame).
    ///
    /// - Parameter contextTerms: Glossary terms for `context.terms`. Empty =>
    ///   no `context` key is sent.
    /// - Parameter languageHints: ISO codes (e.g. `["zh", "en"]`) biasing
    ///   Soniox's auto-detect toward the user's languages — without them short
    ///   utterances drift (zh dictation returning as Korean/Danish). Empty =>
    ///   no `language_hints` key is sent (pure auto-detect).
    public static func configMessageJSON(apiKey: String, contextTerms: [String] = [], languageHints: [String] = []) -> String {
        var payload: [String: Any] = [
            "api_key": apiKey,
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": sampleRate,
            "num_channels": channels,
            "enable_endpoint_detection": true
        ]
        if let context = contextObject(terms: contextTerms) {
            payload["context"] = context
        }
        if !languageHints.isEmpty {
            payload["language_hints"] = languageHints
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The keepalive control frame (text).
    public static let keepaliveMessageJSON = #"{"type":"keepalive"}"#
}
