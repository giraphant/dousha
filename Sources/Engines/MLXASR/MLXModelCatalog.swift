import Foundation

/// A local MLX ASR checkpoint that mlx-audio-swift's StreamingInferenceSession can stream.
public struct MLXModelDescriptor: Sendable, Hashable {
    /// Hugging Face repo id, e.g. "mlx-community/Qwen3-ASR-0.6B-8bit".
    public let repoID: String
    public let displayName: String
    /// Approximate download size, for the install UI (decimal bytes).
    public let downloadBytes: Int64?

    public init(repoID: String, displayName: String, downloadBytes: Int64? = nil) {
        self.repoID = repoID
        self.displayName = displayName
        self.downloadBytes = downloadBytes
    }
}

public enum MLXModelCatalog {
    public static let qwen3ASR_0_6B_8bit = MLXModelDescriptor(repoID: "mlx-community/Qwen3-ASR-0.6B-8bit", displayName: "0.6B (8bit)", downloadBytes: 970_000_000)
    public static let qwen3ASR_1_7B_8bit = MLXModelDescriptor(repoID: "mlx-community/Qwen3-ASR-1.7B-8bit", displayName: "1.7B (8bit)", downloadBytes: 2_470_000_000)
    public static let all: [MLXModelDescriptor] = [qwen3ASR_0_6B_8bit, qwen3ASR_1_7B_8bit]
    public static let defaultModel: MLXModelDescriptor = qwen3ASR_0_6B_8bit
}
