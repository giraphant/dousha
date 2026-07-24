import XCTest
@testable import Dousha

/// A controllable stand-in for the SMAppService-backed launch-at-login state,
/// so we can exercise the enable/disable/error contract the settings UI relies
/// on without touching the real login-item database.
private final class FakeLaunchAtLogin {
    var enabled: Bool
    var errorToThrow: Error?

    init(enabled: Bool = false) { self.enabled = enabled }

    func setEnabled(_ enabled: Bool) throws {
        if let errorToThrow { throw errorToThrow }
        self.enabled = enabled
    }
}

private struct DummyError: Error {}

final class SettingsActionsTests: XCTestCase {
    /// SettingsActions is the seam the SwiftUI panes call. Verify a set of
    /// closures backed by simple state route through correctly: reading
    /// reflects current state, and setting mutates it.
    // @MainActor: SettingsActions' closures are @MainActor (UI-side actions).
    @MainActor
    func testSettingsActions_routeThroughToBackingState() throws {
        let fake = FakeLaunchAtLogin(enabled: false)
        var dockVisible = false
        var menuBarVisible = true
        var doubaoResets = 0

        let actions = SettingsActions(
            isLaunchAtLoginEnabled: { fake.enabled },
            setLaunchAtLogin: { try fake.setEnabled($0) },
            isDockIconVisible: { dockVisible },
            setDockIconVisible: { dockVisible = $0 },
            isMenuBarIconVisible: { menuBarVisible },
            setMenuBarIconVisible: { menuBarVisible = $0 },
            resetDoubaoCredentials: { doubaoResets += 1 },
            retranscribe: { _ in },
            canRetranscribe: { true }
        )

        XCTAssertFalse(actions.isLaunchAtLoginEnabled())
        try actions.setLaunchAtLogin(true)
        XCTAssertTrue(actions.isLaunchAtLoginEnabled())

        // On failure the state must not flip — the UI reverts the toggle to this.
        fake.errorToThrow = DummyError()
        XCTAssertThrowsError(try actions.setLaunchAtLogin(false))
        XCTAssertTrue(actions.isLaunchAtLoginEnabled())
        fake.errorToThrow = nil

        XCTAssertFalse(actions.isDockIconVisible())
        actions.setDockIconVisible(true)
        XCTAssertTrue(actions.isDockIconVisible())

        XCTAssertTrue(actions.isMenuBarIconVisible())
        actions.setMenuBarIconVisible(false)
        XCTAssertFalse(actions.isMenuBarIconVisible())

        actions.resetDoubaoCredentials()
        XCTAssertEqual(doubaoResets, 1)
    }
}
