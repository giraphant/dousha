import Foundation

public enum MLXASRError: LocalizedError, Sendable, Equatable {
    case notImplemented
    case modelLoadFailed(String)
    case modelNotReady
    case finalTimedOut

    public var errorDescription: String? {
        switch self {
        case .notImplemented: "本地语音识别尚未实现"
        case .modelLoadFailed(let message): "本地模型加载失败：\(message)"
        case .modelNotReady: "本地模型尚未就绪"
        case .finalTimedOut: "本地语音识别结果等待超时"
        }
    }
}

public enum MLXASRSupport {
    /// int16 little-endian mono PCM → Float samples in [-1, 1).
    public static func floatSamples(fromPCM16LE data: Data) -> [Float] {
        data.withUnsafeBytes { bytes in
            let bytes = bytes.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count - bytes.count % 2, by: 2).map { index in
                let bits = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
                return Float(Int16(bitPattern: bits)) / 32_768
            }
        }
    }

    /// Dousha language identifier ("zh-CN", "en-US", "auto", …) → Qwen3 language name, nil = auto-detect.
    public static func qwenLanguage(forIdentifier identifier: String) -> String? {
        let identifier = identifier.lowercased()
        if identifier.hasPrefix("zh") { return "Chinese" }
        if identifier.hasPrefix("en") { return "English" }
        return nil
    }
}
