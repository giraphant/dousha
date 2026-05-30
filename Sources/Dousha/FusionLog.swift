import Foundation

/// 双枪融合的对比日志。每次录音把各家原始转录 + LLM 合并结果追加到
/// `~/Library/Logs/Dousha/fusion.log`,事后翻着对比,判断融合到底有没有帮上忙。
/// 粘贴给用户的是融合后的结果;这个文件只是给我们做实验观测用。
enum FusionLog {
    private static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Dousha", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fusion.log")
    }()

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    struct Timing {
        let soniox: TimeInterval   // Soniox 重转耗时
        let doubao: TimeInterval   // 豆包重转耗时
        let llm: TimeInterval      // LLM 融合耗时
        let total: TimeInterval    // 总耗时 (含串行等待)
    }

    static func append(soniox: String, doubao: String, fused: String,
                       traceId: String?, timing: Timing? = nil) {
        let ts = timestampFormatter.string(from: Date())
        let trace = traceId ?? "none"
        let timingLine = timing.map {
            "  ⏱ Soniox=\(String(format: "%.2f", $0.soniox))s  豆包=\(String(format: "%.2f", $0.doubao))s  LLM=\(String(format: "%.2f", $0.llm))s  总计=\(String(format: "%.2f", $0.total))s"
        } ?? ""
        let entry = """
        ── \(ts)  trace=\(trace)
        \(timingLine)
        Soniox: \(soniox)
        豆包  : \(doubao)
        融合  : \(fused)

        """
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // 文件还不存在:直接创建。
            try? data.write(to: fileURL)
        }
    }
}
