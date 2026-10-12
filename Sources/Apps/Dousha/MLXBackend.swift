import Foundation
import MLXASR
import ASRSupport

/// Adapter bridging the standalone MLXASR package to Dousha's push-capture
/// model: `MLXStreamingASR` receives PCM pushed from the shared `AudioTapHub`
/// via `ingest`. `setLanguage` is a no-op — the per-recording language is read
/// from `Preferences` in `beginSession` and handed to Qwen3 as a language name.
final class MLXBackend: PCMCaptureEngine {
    private let asr = MLXStreamingASR(model: MLXModelCatalog.defaultModel, store: .shared)

    func setLanguage(_ identifier: String) {}

    // MARK: - PushCaptureEngine

    func beginSession(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                      onError: @escaping @Sendable (Error) -> Void) async {
        // Snapshot the language at recording start so a Settings change
        // mid-recording can't alter the active session.
        let language = MLXASRSupport.qwenLanguage(forIdentifier: Preferences.shared.language)
        // The glossary is not applied here yet: the upstream streaming session
        // lacks context support (giraphant/dousha#53). TranscriptCorrector still
        // applies local corrections downstream.
        await asr.prepareSession(onPartial: onPartial, onError: onError, language: language)
    }

    func openStream() { asr.openStream() }

    func ingest(_ pcm: Data) { asr.ingest(pcm) }

    func finish(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        asr.stop(completion: completion)
    }

    func cancelSession() { asr.cancel() }
}
