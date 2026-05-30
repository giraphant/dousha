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
