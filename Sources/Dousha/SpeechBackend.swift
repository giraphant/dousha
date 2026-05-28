import Foundation
import DoubaoASR

enum Engine: String, CaseIterable {
    case apple
    case doubao

    var displayName: String {
        switch self {
        case .apple:  return "Apple Speech"
        case .doubao: return "Doubao IME"
        }
    }
}

protocol SpeechBackend: AnyObject {
    func setLanguage(_ identifier: String)
    func start(onPartial: @escaping @Sendable (String) -> Void,
               onAudioLevel: @escaping @Sendable (Float) -> Void,
               onError: @escaping @Sendable (Error) -> Void)
    func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void)

    /// Aborts an in-flight session and discards everything captured so far.
    /// MUST NOT call any of the start() callbacks, MUST NOT call any pending
    /// stop() completion, and MUST leave no stale saved-audio file behind that
    /// could fool retranscribe. Safe to call when not running (no-op).
    func cancel()

    /// Re-runs ASR on the last saved WAV from the most recent recording, if
    /// the backend supports it. Returns nil text if there is no saved audio
    /// or the backend cannot replay it.
    ///
    /// - Parameter parentTraceId: The trace ID of the original recording that
    ///   triggered this replay, if known. Backends that create a new trace ID
    ///   for the replay session log the parent alongside it so `grep` on the
    ///   original ID also finds the replay entry.
    func retranscribeLastRecording(parentTraceId: String?, completion: @escaping @Sendable (String?) -> Void)
}

extension SpeechBackend {
    /// Convenience overload for callers that have no parent trace ID (e.g.
    /// manual menu actions). Delegates to the required method with `nil`.
    func retranscribeLastRecording(completion: @escaping @Sendable (String?) -> Void) {
        retranscribeLastRecording(parentTraceId: nil, completion: completion)
    }
}

enum SpeechBackendFactory {
    static func make(engine: Engine, language: String) -> SpeechBackend {
        switch engine {
        case .apple:
            return AppleSpeechBackend(language: language)
        case .doubao:
            return DoubaoBackend(language: language)
        }
    }
}
