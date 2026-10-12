import Foundation
import MLXASR
import ASRSupport

/// Adapter bridging the standalone MLXASR package to Dousha's push-capture
/// model: `MLXStreamingASR` receives PCM pushed from the shared `AudioTapHub`
/// via `ingest`. `setLanguage` is a no-op — the per-recording language is read
/// from `Preferences` in `beginSession`; the engine maps that identifier to Qwen3.
final class MLXBackend: PCMCaptureEngine {
    typealias PrepareSession = @Sendable (
        @escaping @Sendable (PartialTranscript) -> Void,
        @escaping @Sendable (Error) -> Void,
        String?,
        String
    ) async -> Void

    private let asr: MLXStreamingASR
    private let preferences: Preferences
    private let prepareSession: PrepareSession

    init(model: MLXModelDescriptor = MLXModelCatalog.defaultModel,
         preferences: Preferences = .shared, prepareSession: PrepareSession? = nil) {
        let asr = MLXStreamingASR(model: model, store: .shared)
        self.asr = asr
        self.preferences = preferences
        self.prepareSession = prepareSession ?? { [asr] onPartial, onError, language, context in
            await asr.prepareSession(onPartial: onPartial, onError: onError, language: language, context: context)
        }
    }

    func setLanguage(_ identifier: String) {}

    // MARK: - PushCaptureEngine

    func beginSession(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                      onError: @escaping @Sendable (Error) -> Void) async {
        // Snapshot the language at recording start so a Settings change
        // mid-recording can't alter the active session.
        // Pass the Dousha identifier unchanged: mapping twice turns Chinese
        // into auto-detect because "Chinese" is not a "zh" identifier.
        let language = preferences.language
        let terms = preferences.glossaryEnabled
            ? GlossaryContext.normalize(preferences.glossaryTerms)
            : []
        // Qwen receives this verbatim as its system context, only in the final
        // full-audio pass; streaming has no context input (giraphant/dousha#53).
        let context = terms.isEmpty ? "" : "Vocabulary:\n" + terms.map { "- \($0)" }.joined(separator: "\n")
        await prepareSession(onPartial, onError, language, context)
    }

    func openStream() { asr.openStream() }

    func ingest(_ pcm: Data) { asr.ingest(pcm) }

    func finish(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        asr.stop(completion: completion)
    }

    func cancelSession() { asr.cancel() }
}
