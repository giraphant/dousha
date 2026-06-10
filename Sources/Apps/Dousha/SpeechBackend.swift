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

/// One streamed event from a recording session. `Sendable` so it can cross from
/// the backend's work task to the controller's `@MainActor` consumer. `.error`
/// carries the `localizedDescription` (all the controller and logging ever use)
/// rather than `any Error`, which keeps the enum `Sendable`.
enum RecordingEvent: Sendable {
    case partial(PartialTranscript)
    case audioLevel(Float)
    case error(String)
    case final(TranscriptionResult)
}

protocol SpeechBackend: AnyObject, Sendable {
    func setLanguage(_ identifier: String)
    /// Start one session. The returned stream lives for this session only:
    /// during recording it yields `.partial` / `.audioLevel` / `.error`; after
    /// `stop()` it yields exactly one terminal `.final(result)` then finishes;
    /// `cancel()` finishes the stream with no `.final`.
    func start() -> AsyncStream<RecordingEvent>
    /// Request finalization. Fire-and-forget — the final arrives as a `.final`
    /// stream event. Safe to call only once per session.
    func stop()

    /// Aborts an in-flight session and discards everything captured so far.
    /// Finishes the stream with no `.final`, MUST leave no stale saved-audio
    /// file behind. Safe to call when not running (no-op).
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
