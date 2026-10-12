import Foundation
import ASRSupport
import ConcurrencySupport

/// One local streaming recognizer per recording, mirroring SonioxASR/DoubaoASR's
/// lifecycle: prepareSession (no I/O) → openStream (load model + start stream)
/// → ingest (int16 16 kHz mono PCM, called from the audio thread) → stop / cancel.
public actor MLXStreamingASR {
    private let model: MLXModelDescriptor
    private let store: MLXModelStore
    private var onPartial: (@Sendable (PartialTranscript) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?
    private var language: String?

    public init(model: MLXModelDescriptor = MLXModelCatalog.defaultModel, store: MLXModelStore = .shared) {
        self.model = model
        self.store = store
    }

    public func prepareSession(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                               onError: @escaping @Sendable (Error) -> Void,
                               language: String?) {
        self.onPartial = onPartial
        self.onError = onError
        self.language = language
    }

    public nonisolated func openStream() {
        Task {
            guard let onError = await self.onError else { return }
            DispatchQueue.main.async {
                onError(MLXASRError.notImplemented)
            }
        }
    }

    public nonisolated func ingest(_ pcm: Data) {}

    public nonisolated func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        DispatchQueue.main.async {
            completion(TranscriptionResult(text: ""))
        }
    }

    public nonisolated func cancel() {}
}
