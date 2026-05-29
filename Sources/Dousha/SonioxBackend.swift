import Foundation
import SonioxASR
import ASRSupport

/// Adapter bridging the standalone SonioxASR package to Dousha's
/// `SpeechBackend` protocol. Soniox auto-detects language so `setLanguage`
/// is a no-op.
final class SonioxBackend: SpeechBackend {
    private let asr: SonioxASR

    init(apiKey: String, mode: SonioxMode) {
        self.asr = SonioxASR(apiKey: apiKey, mode: mode)
    }

    func setLanguage(_ identifier: String) {}

    func start(onPartial: @escaping @Sendable (String) -> Void,
               onAudioLevel: @escaping @Sendable (Float) -> Void,
               onError: @escaping @Sendable (Error) -> Void) {
        // Snapshot the shared glossary into Soniox's context.terms at recording
        // start (QUA-133). Read synchronously so a Settings change mid-recording
        // can't alter the active session.
        let prefs = Preferences.shared
        let terms = prefs.glossaryEnabled
            ? GlossaryContext.normalize(prefs.glossaryTerms)
            : []
        asr.start(onPartial: onPartial, onAudioLevel: onAudioLevel, onError: onError, contextTerms: terms)
    }

    func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        asr.stop(completion: completion)
    }

    func cancel() {
        asr.cancel()
    }

    var canRetranscribe: Bool {
        FileManager.default.fileExists(atPath: SonioxASR.savedAudioURL.path)
    }

    func retranscribeLastRecording(parentTraceId: String?, completion: @escaping @Sendable (String?) -> Void) {
        let url = SonioxASR.savedAudioURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            completion(nil)
            return
        }
        Task {
            let text = await asr.retranscribe(wavURL: url, parentTraceId: parentTraceId)
            DispatchQueue.main.async { completion(text) }
        }
    }
}
