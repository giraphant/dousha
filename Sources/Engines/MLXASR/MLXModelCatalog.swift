import Foundation

/// A local MLX ASR checkpoint that mlx-audio-swift's StreamingInferenceSession can stream.
public struct MLXModelDescriptor: Sendable, Hashable {
    /// Hugging Face repo id, e.g. "mlx-community/Qwen3-ASR-0.6B-8bit".
    public let repoID: String
    public let displayName: String

    public init(repoID: String, displayName: String) {
        self.repoID = repoID
        self.displayName = displayName
    }
}

public enum MLXModelCatalog {
    public static let qwen3ASR_0_6B_8bit = MLXModelDescriptor(repoID: "mlx-community/Qwen3-ASR-0.6B-8bit", displayName: "Qwen3-ASR 0.6B (8-bit)")
    public static let qwen3ASR_1_7B_8bit = MLXModelDescriptor(repoID: "mlx-community/Qwen3-ASR-1.7B-8bit", displayName: "Qwen3-ASR 1.7B (8-bit)")
    public static let all: [MLXModelDescriptor] = [qwen3ASR_0_6B_8bit, qwen3ASR_1_7B_8bit]
    public static let defaultModel: MLXModelDescriptor = qwen3ASR_0_6B_8bit
}
