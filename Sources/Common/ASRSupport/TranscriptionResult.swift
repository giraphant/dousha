import Foundation

/// What `SpeechBackend.stop()` hands back to the caller.
public struct TranscriptionResult: Sendable {
    public let text: String
    /// Doubao request_id for trace correlation across logs and results.
    public let traceId: String?

    public init(text: String, traceId: String? = nil) {
        self.text = text
        self.traceId = traceId
    }
}
