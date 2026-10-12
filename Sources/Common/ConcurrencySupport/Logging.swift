import Foundation
import os

private let _doushaLogger = Logger(subsystem: "com.dousha.app", category: "general")

/// Logging helper that forces messages public (non-redacted) in macOS
/// unified logging. Swift string interpolation defaults to private
/// (redacted) in os.Logger, which hides content from `log show` and
/// Console.app. Centralised here so both DoubaoASR and the Dousha app
/// target route through the same subsystem/category.
///
/// When enabled, also tees every line to a persistent on-disk log so failures can be
/// inspected after the fact — the unified-log store has a short retention
/// window (`log show` routinely returns nothing a day or two later), which
/// made past failures (stuck Doubao credentials, silent capture, near-hangs)
/// impossible to diagnose. `fusion.log` only records *successful* fusions, so
/// it never captured a failure either. This file is the durable record.
public func doushaLog(_ message: String) {
    _doushaLogger.log("\(message, privacy: .public)")
    DoushaFileLog.shared?.append(message)
}

/// Append-only persistent log at `~/Library/Logs/Dousha/dousha.log`, mirroring
/// every `doushaLog` line with a timestamp. Thread-safe via a private serial
/// queue, including the enabled flag and formatter; rotates at ~5 MB on open.
public final class DoushaFileLog: @unchecked Sendable {
    public static let shared = NSClassFromString("XCTestCase") == nil ? DoushaFileLog() : nil

    private let queue = DispatchQueue(label: "com.dousha.app.filelog")
    public let fileURL: URL
    private var enabled = true
    private var handle: FileHandle?
    private let maxBytes: UInt64 = 5 * 1024 * 1024

    private lazy var stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Dousha/dousha.log")) {
        self.fileURL = fileURL
    }

    /// Returns only after earlier writes finish; later appends obey the new value.
    public func setEnabled(_ enabled: Bool) {
        queue.sync { self.enabled = enabled }
    }

    public func deleteLogs() throws {
        try queue.sync {
            try handle?.close()
            handle = nil
            for url in [fileURL, fileURL.appendingPathExtension("1")]
                where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func append(_ message: String) {
        queue.async { [weak self] in
            guard let self, self.enabled else { return }
            let url = self.fileURL
            let line = "\(self.stamp.string(from: Date()))  \(message)\n"
            if self.handle == nil {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                self.rotateIfNeeded(url)
                self.handle = try? FileHandle(forWritingTo: url)
                _ = try? self.handle?.seekToEnd()
            }
            guard let data = line.data(using: .utf8) else { return }
            try? self.handle?.write(contentsOf: data)
        }
    }

    /// If the existing log already exceeds the cap, roll it to `dousha.log.1`
    /// (overwriting any previous roll) and start fresh before opening the handle.
    private func rotateIfNeeded(_ url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
        guard let size, size > maxBytes else { return }
        let rolled = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rolled)
        try? FileManager.default.moveItem(at: url, to: rolled)
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
}
