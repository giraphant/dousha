import Foundation
import DoubaoASR
import ASRSupport

/// Adapter that bridges the standalone DoubaoASR package to Dousha's push-capture
/// model: `DoubaoASR` no longer captures the mic, it receives PCM pushed from the
/// shared `AudioTapHub` via `ingest`. Doubao auto-detects language so
/// `setLanguage` is a no-op.
final class DoubaoBackend: SpeechBackend, PCMCaptureEngine, @unchecked Sendable {
    private let asr = DoubaoASR()

    init(language: String) { _ = language }

    func setLanguage(_ identifier: String) {}

    // MARK: - SpeechBackend (hub-less degenerate/test path)

    func start(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
               onAudioLevel: @escaping @Sendable (Float) -> Void,
               onError: @escaping @Sendable (Error) -> Void) {
        Task {
            await beginSession(onPartial: onPartial, onError: onError)
            openStream()
        }
    }

    func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        finish(completion: completion)
    }

    func cancel() { cancelSession() }

    // MARK: - PushCaptureEngine

    func beginSession(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                      onError: @escaping @Sendable (Error) -> Void) async {
        // Snapshot the glossary into a context hint at recording start (QUA-133).
        // Read synchronously here so a Settings change mid-recording can't alter
        // the active session.
        let prefs = Preferences.shared
        let contextHint = prefs.glossaryEnabled
            ? GlossaryContext.encode(prefs.glossaryTerms)
            : ""
        await asr.prepareSession(onPartial: onPartial, onError: onError, contextHint: contextHint)
    }

    func openStream() { asr.openStream() }

    func ingest(_ pcm: Data) { asr.ingest(pcm) }

    func finish(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        asr.stop(completion: completion)
    }

    func cancelSession() { asr.cancel() }
}
