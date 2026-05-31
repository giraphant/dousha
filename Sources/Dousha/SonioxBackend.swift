import Foundation
import SonioxASR
import ASRSupport

/// Adapter bridging the standalone SonioxASR package to Dousha's push-capture
/// model: `SonioxASR` no longer captures the mic, it receives PCM pushed from
/// the shared `AudioTapHub` via `ingest` (a no-op in async mode, which uploads
/// the hub's shared WAV instead). `setLanguage` is a no-op — the per-recording
/// language is read from `Preferences` in `beginSession` and handed to Soniox
/// as `language_hints` (see `languageHints(for:)`).
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
        let hints = SonioxBackend.languageHints(for: prefs.language)
        await asr.prepareSession(onPartial: onPartial, onError: onError,
                                 contextTerms: terms, languageHints: hints)
    }

    /// Soniox auto-detects language, which drifts on short utterances (zh
    /// dictation returning as Korean / Danish). Bias it with `language_hints`
    /// derived from the user's selected primary language: that family first, the
    /// other of zh/en as a fallback for mixed zh/en speech. Other languages
    /// (ja/ko) stay on pure auto-detect for now (empty hints) — only zh/en are
    /// wired per the current product decision.
    static func languageHints(for language: String) -> [String] {
        if language.hasPrefix("zh") { return ["zh", "en"] }
        if language.hasPrefix("en") { return ["en", "zh"] }
        return []
    }

    func openStream() { asr.openStream() }

    func ingest(_ pcm: Data) { asr.ingest(pcm) }

    func finish(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        asr.stop(completion: completion)
    }

    func cancelSession() { asr.cancel() }
}
