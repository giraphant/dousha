import Foundation
import DoubaoASR
import ASRSupport

/// Adapter that bridges the standalone DoubaoASR package to Dousha's
/// `SpeechBackend` protocol. Doubao auto-detects language so `setLanguage` is a no-op.
final class DoubaoBackend: SpeechBackend {
    private let asr = DoubaoASR()

    init(language: String) { _ = language }

    func setLanguage(_ identifier: String) {}

    func start(onPartial: @escaping @Sendable (String) -> Void,
               onAudioLevel: @escaping @Sendable (Float) -> Void,
               onError: @escaping @Sendable (Error) -> Void) {
        // Snapshot the glossary into a context hint at recording start (QUA-133).
        // Read synchronously here so a Settings change mid-recording can't alter
        // the active session.
        let prefs = Preferences.shared
        let contextHint = prefs.glossaryEnabled
            ? GlossaryContext.encode(prefs.glossaryTerms)
            : ""
        asr.start(onPartial: onPartial, onAudioLevel: onAudioLevel, onError: onError, contextHint: contextHint)
    }

    func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        asr.stop(completion: completion)
    }

    func cancel() {
        asr.cancel()
    }

    var canRetranscribe: Bool {
        FileManager.default.fileExists(atPath: DoubaoASR.savedAudioURL.path)
    }

    func retranscribeLastRecording(parentTraceId: String?, completion: @escaping @Sendable (String?) -> Void) {
        let url = DoubaoASR.savedAudioURL
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
