import Foundation

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
    func stop(completion: @escaping @Sendable (String) -> Void)
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
