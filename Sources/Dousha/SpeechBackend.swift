import Foundation
import AVFoundation
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
    /// could fool a later read of the shared WAV. Safe to call when not running (no-op).
    func cancel()
}

/// An engine that no longer captures its own mic — it receives audio pushed
/// from the shared `AudioTapHub` (spec §1). `MultiEngineBackend` drives the
/// two phases so capture can start only once every engine's session state is
/// reset (otherwise an early pushed buffer would be dropped → lost opening
/// words):
///
///   1. `beginSession` — reset session state, install callbacks, mark the
///      engine ready to accept `ingest`. Returns once that's done (no network).
///   2. `openStream` — open the network stream / recognizer. Audio pushed in
///      the gap is buffered by the engine and flushed when the stream is ready.
protocol PushCaptureEngine: AnyObject, Sendable {
    func setLanguage(_ identifier: String)
    func beginSession(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                      onError: @escaping @Sendable (Error) -> Void) async
    func openStream()
    func finish(completion: @escaping @Sendable (TranscriptionResult) -> Void)
    func cancelSession()
}

/// A `PushCaptureEngine` that consumes int16 16 kHz mono PCM (Doubao, Soniox).
protocol PCMCaptureEngine: PushCaptureEngine {
    func ingest(_ pcm: Data)
}

/// A `PushCaptureEngine` that consumes the native mic buffer (Apple Speech).
protocol BufferCaptureEngine: PushCaptureEngine {
    func ingest(_ buffer: AVAudioPCMBuffer)
}

enum SpeechBackendFactory {
    static func make(engine: Engine, language: String) -> PushCaptureEngine {
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
