import Foundation

/// The seam between the SwiftUI settings panes and the app-level effects that
/// reach beyond `Preferences` — login-item registration, Dock-icon policy,
/// menu-bar visibility, and Doubao credential reset. `AppDelegate` builds one
/// of these and injects it into the settings view.
///
/// Routine settings (hotkey, Soniox, LLM text fields) keep talking to
/// `Preferences.shared` + `NotificationCenter` directly; only the genuinely
/// system-touching toggles go through here.
struct SettingsActions {
    /// Current login-item state (read from the system, not the prefs mirror).
    var isLaunchAtLoginEnabled: () -> Bool
    /// Enable/disable launch at login; throws so the UI can surface failures.
    var setLaunchAtLogin: (Bool) throws -> Void

    /// Current Dock-icon visibility (activation policy).
    var isDockIconVisible: () -> Bool
    /// Show/hide the Dock icon, applied immediately.
    var setDockIconVisible: (Bool) -> Void

    /// Current menu-bar status-item visibility.
    var isMenuBarIconVisible: () -> Bool
    /// Show/hide the menu-bar status item, applied immediately.
    var setMenuBarIconVisible: (Bool) -> Void

    /// Reset cached Doubao credentials (shows its own confirmation alert).
    var resetDoubaoCredentials: () -> Void
}
