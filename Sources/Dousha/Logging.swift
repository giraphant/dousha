import Foundation
import os

private let _doushaLogger = Logger(subsystem: "com.dousha.app", category: "general")

/// Logging helper that forces messages public (non-redacted) in macOS
/// unified logging. Swift NSLog defaults to private for interpolated
/// strings, which hides content from `log show` and Console.app.
func doushaLog(_ message: String) {
    _doushaLogger.log("\(message, privacy: .public)")
}
