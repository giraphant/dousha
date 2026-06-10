import AppKit

/// Tracks the frontmost application, ignoring activations of Dousha itself.
/// Designed so the floating HUD's "left side" can display where dictated text
/// will go, even while the user is interacting with Dousha's Settings window.
///
/// `@MainActor`: AppKit-only (NSWorkspace), its `onChange` sink writes the HUD
/// model, and its activation observer is delivered on `.main`.
@MainActor
final class AppFocusTracker {
    struct Focus: Equatable {
        let icon: NSImage
        let name: String
    }

    private(set) var current: Focus?
    var onChange: ((Focus?) -> Void)?

    private let selfBundleId: String
    // nonisolated(unsafe): written only on the main actor (in `start()`) and read
    // only from the nonisolated `deinit`, which has exclusive access — so the
    // unaudited-Sendable token can be removed during teardown.
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    init(selfBundleId: String) {
        self.selfBundleId = selfBundleId
        seedFromFrontmost()
    }

    deinit {
        if let observer = observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Starts listening to NSWorkspace activations. Call once after init.
    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Delivered on `.main` (queue above), so assume main-actor isolation
            // to reach the @MainActor tracker state.
            MainActor.assumeIsolated {
                self?.applyActivation(
                    bundleId: app.bundleIdentifier,
                    name: app.localizedName ?? app.bundleIdentifier ?? "",
                    icon: app.icon ?? NSImage()
                )
            }
        }
    }

    /// Returns true if an activation for this bundleId should be ignored.
    func shouldIgnore(bundleId: String?) -> Bool {
        return bundleId == selfBundleId
    }

    /// Public for tests; pure function — given an activation, decide whether to
    /// update `current` and emit `onChange`.
    func applyActivation(bundleId: String?, name: String, icon: NSImage) {
        if shouldIgnore(bundleId: bundleId) { return }
        let focus = Focus(icon: icon, name: name)
        current = focus
        onChange?(focus)
    }

    private func seedFromFrontmost() {
        if let app = NSWorkspace.shared.frontmostApplication,
           !shouldIgnore(bundleId: app.bundleIdentifier) {
            current = Focus(
                icon: app.icon ?? NSImage(),
                name: app.localizedName ?? app.bundleIdentifier ?? ""
            )
        }
    }
}
