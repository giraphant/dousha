import Foundation

/// Temporary file-based debug log for QUA-145 multi-engine / refine inspection.
/// The app's `os_log` output isn't readable via `log show` in this dev
/// environment, so we append to a plain file we can `cat`:
///   ~/Library/Caches/Dousha/qua145_debug.log
///
/// Remove (or gate behind a debug flag) once QUA-145 tuning is done.
func qua145Debug(_ message: String) {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Dousha", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("qua145_debug.log")
    let line = "\(Date()) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}
