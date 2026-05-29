import Foundation
import DoubaoASR
import SonioxASR
import ASRSupport

enum Engine: String, CaseIterable {
    case apple
    case doubao
    case soniox

    var displayName: String {
        switch self {
        case .apple:  return "Apple Speech"
        case .doubao: return "豆包"
        case .soniox: return "Soniox"
        }
    }
}

protocol SpeechBackend: AnyObject {
    func setLanguage(_ identifier: String)
    func start(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
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

    /// Whether this backend can replay its last recording (a saved WAV exists
    /// and the backend supports `retranscribeLastRecording`). Used to gate the
    /// "重新转写上次录音" menu item. Defaults to false.
    var canRetranscribe: Bool { get }
}

extension SpeechBackend {
    /// Convenience overload for callers that have no parent trace ID (e.g.
    /// manual menu actions). Delegates to the required method with `nil`.
    func retranscribeLastRecording(completion: @escaping @Sendable (String?) -> Void) {
        retranscribeLastRecording(parentTraceId: nil, completion: completion)
    }

    var canRetranscribe: Bool { false }
}

enum SpeechBackendFactory {
    static func make(engine: Engine, language: String) -> SpeechBackend {
        switch engine {
        case .apple:
            return AppleSpeechBackend(language: language)
        case .doubao:
            return DoubaoBackend(language: language)
        case .soniox:
            return SonioxBackend(apiKey: Preferences.shared.sonioxAPIKey,
                                 mode: Preferences.shared.sonioxMode)
        }
    }
}
