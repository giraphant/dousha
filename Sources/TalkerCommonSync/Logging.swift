import Foundation
import os

private let _doushaLogger = Logger(subsystem: "com.dousha.app", category: "general")

/// Logging helper that forces messages public (non-redacted) in macOS
/// unified logging. Swift string interpolation defaults to private
/// (redacted) in os.Logger, which hides content from `log show` and
/// Console.app. Centralised here so both DoubaoASR and the Dousha app
/// target route through the same subsystem/category.
public func doushaLog(_ message: String) {
    _doushaLogger.log("\(message, privacy: .public)")
}
