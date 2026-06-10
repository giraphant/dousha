import Foundation
import DoubaoASR
import ASRSupport

/// Adapter that bridges the standalone DoubaoASR package to Dousha's push-capture
/// model: `DoubaoASR` no longer captures the mic, it receives PCM pushed from the
/// shared `AudioTapHub` via `ingest`. Doubao auto-detects language so
/// `setLanguage` is a no-op.
final class DoubaoBackend: PCMCaptureEngine, @unchecked Sendable {
    private let asr = DoubaoASR()

    init(language: String) { _ = language }

    func setLanguage(_ identifier: String) {}

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
