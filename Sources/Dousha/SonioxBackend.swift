import Foundation
import SonioxASR
import ASRSupport

/// Adapter bridging the standalone SonioxASR package to Dousha's push-capture
/// model: `SonioxASR` no longer captures the mic, it receives PCM pushed from
/// the shared `AudioTapHub` via `ingest` (a no-op in async mode, which uploads
/// the hub's shared WAV instead). Soniox auto-detects language so `setLanguage`
/// is a no-op.
final class SonioxBackend: PCMCaptureEngine, @unchecked Sendable {
    private let asr: SonioxASR

    init(apiKey: String, mode: SonioxMode) {
        self.asr = SonioxASR(apiKey: apiKey, mode: mode)
    }

    func setLanguage(_ identifier: String) {}

    // MARK: - PushCaptureEngine

    func beginSession(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                      onError: @escaping @Sendable (Error) -> Void) async {
        // Snapshot the shared glossary into Soniox's context.terms at recording
        // start (QUA-133). Read synchronously so a Settings change mid-recording
        // can't alter the active session.
        let prefs = Preferences.shared
        let terms = prefs.glossaryEnabled
            ? GlossaryContext.normalize(prefs.glossaryTerms)
            : []
        await asr.prepareSession(onPartial: onPartial, onError: onError, contextTerms: terms)
    }

    func openStream() { asr.openStream() }

    func ingest(_ pcm: Data) { asr.ingest(pcm) }

    func finish(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        asr.stop(completion: completion)
    }

    func cancelSession() { asr.cancel() }
}
