import Foundation
#if canImport(os)
import os

private let _doushaLogger = Logger(subsystem: "com.dousha.app", category: "general")
#endif

/// Logging helper that forces messages public (non-redacted) in macOS
/// unified logging. Swift string interpolation defaults to private
/// (redacted) in os.Logger, which hides content from `log show` and
/// Console.app. Centralised here so both DoubaoASR and the Dousha app
/// target route through the same subsystem/category.
///
/// Also tees every line to a persistent on-disk log so failures can be
/// inspected after the fact — the unified-log store has a short retention
/// window (`log show` routinely returns nothing a day or two later), which
/// made past failures (stuck Doubao credentials, silent capture, near-hangs)
/// impossible to diagnose. `fusion.log` only records *successful* fusions, so
/// it never captured a failure either. This file is the durable record.
public func doushaLog(_ message: String) {
    // Unified logging is Darwin-only; on other platforms (Windows port,
    // QUA-209) the persistent file log below is the sole sink.
    #if canImport(os)
    _doushaLogger.log("\(message, privacy: .public)")
    #endif
    DoushaFileLog.shared.append(message)
}

/// Append-only persistent log at `~/Library/Logs/Dousha/dousha.log`, mirroring
/// every `doushaLog` line with a timestamp. Thread-safe via a private serial
/// queue; rotates once at ~5 MB so it can't grow unbounded.
final class DoushaFileLog: @unchecked Sendable {
    static let shared = DoushaFileLog()

    private let queue = DispatchQueue(label: "com.dousha.app.filelog")
    private let fileURL: URL?
    private var handle: FileHandle?
    private let maxBytes: UInt64 = 5 * 1024 * 1024

    private lazy var stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        // macOS: ~/Library/Logs/Dousha. Windows: .libraryDirectory resolves to
        // nothing useful, so live next to the credential store instead —
        // %LOCALAPPDATA%\Dousha\Logs (QUA-209).
        #if os(Windows)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dirOrNil = base?.appendingPathComponent("Dousha/Logs", isDirectory: true)
        #else
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        let dirOrNil = base?.appendingPathComponent("Logs/Dousha", isDirectory: true)
        #endif
        guard let dir = dirOrNil else {
            fileURL = nil
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("dousha.log")
    }

    func append(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async { [weak self] in
            guard let self, let url = self.fileURL else { return }
            if self.handle == nil {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                self.rotateIfNeeded(url)
                self.handle = try? FileHandle(forWritingTo: url)
                try? self.handle?.seekToEnd()
            }
            guard let data = line.data(using: .utf8) else { return }
            try? self.handle?.write(contentsOf: data)
        }
    }

    /// If the existing log already exceeds the cap, roll it to `dousha.log.1`
    /// (overwriting any previous roll) and start fresh. Called once per process
    /// before the handle is opened.
    private func rotateIfNeeded(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
        guard let size, size > maxBytes else { return }
        let rolled = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rolled)
        try? FileManager.default.moveItem(at: url, to: rolled)
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
}
