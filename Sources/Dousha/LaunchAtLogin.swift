import Foundation
import ServiceManagement

/// Abstracts "is the app a login item, and can I flip that" so the settings
/// UI and AppDelegate depend on a protocol rather than `SMAppService` directly.
/// This keeps the system call behind a seam we can fake in unit tests.
protocol LaunchAtLoginManaging {
    /// Whether the app is currently registered to launch at login.
    var isEnabled: Bool { get }
    /// Register (`true`) or unregister (`false`) the app as a login item.
    /// Throws if the system rejects the change.
    func setEnabled(_ enabled: Bool) throws
}

/// Production implementation backed by `SMAppService.mainApp` (macOS 13+).
final class LaunchAtLoginController: LaunchAtLoginManaging {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            // `register()` is idempotent — re-registering an already-enabled
            // service is fine and simply refreshes it.
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
