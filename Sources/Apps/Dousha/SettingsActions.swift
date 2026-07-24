import Foundation

/// The seam between the SwiftUI settings panes and the app-level effects that
/// reach beyond `Preferences` — login-item registration, Dock-icon policy,
/// menu-bar visibility, and Doubao credential reset. `AppDelegate` builds one
/// of these and injects it into the settings view.
///
/// Routine settings (hotkey, Soniox, LLM text fields) keep talking to
/// `Preferences.shared` + `NotificationCenter` directly; only the genuinely
/// system-touching toggles go through here.
/// The closures are `@MainActor`: they're built by `AppDelegate` (main actor),
/// reach main-actor state (activation policy, the status item, Doubao reset), and
/// are invoked from the SwiftUI settings panes, which run on the main actor.
struct SettingsActions {
    /// Current login-item state (read from the system, not the prefs mirror).
    var isLaunchAtLoginEnabled: @MainActor () -> Bool
    /// Enable/disable launch at login; throws so the UI can surface failures.
    var setLaunchAtLogin: @MainActor (Bool) throws -> Void

    /// Current Dock-icon visibility (activation policy).
    var isDockIconVisible: @MainActor () -> Bool
    /// Show/hide the Dock icon, applied immediately.
    var setDockIconVisible: @MainActor (Bool) -> Void

    /// Current menu-bar status-item visibility.
    var isMenuBarIconVisible: @MainActor () -> Bool
    /// Show/hide the menu-bar status item, applied immediately.
    var setMenuBarIconVisible: @MainActor (Bool) -> Void

    /// Reset cached Doubao credentials (shows its own confirmation alert).
    var resetDoubaoCredentials: @MainActor () -> Void

    /// Re-transcribe a history entry by id (reaches the RecordingController).
    var retranscribe: @MainActor (String) -> Void
    /// Whether a re-transcription may start now (controller idle / error).
    var canRetranscribe: @MainActor () -> Bool
}
