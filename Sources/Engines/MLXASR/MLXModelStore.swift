import Foundation
import MLXAudioSTT
import ConcurrencySupport

private typealias _QwenModel = Qwen3ASRModel

/// Process-wide owner of loaded MLX model weights. Per-recording engines are
/// rebuilt every session; weights must not be. Loading, load coalescing and the
/// exclusive-session lease are implemented by the engine integration.
public actor MLXModelStore {
    public static let shared = MLXModelStore()

    public enum State: Sendable, Equatable {
        case idle
        case loading(repoID: String)
        case ready(repoID: String)
        case failed(repoID: String, message: String)
    }

    public private(set) var state: State = .idle

    public init() {}

    /// Fire-and-forget preload (engine selected in the menu / app launch). Never throws.
    public nonisolated func warmup(_ model: MLXModelDescriptor) {
        doushaLog("[MLX] warmup requested repoID=\(model.repoID) (not implemented)")
    }
}
