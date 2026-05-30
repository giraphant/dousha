import XCTest
@testable import Dousha

/// A controllable stand-in for the SMAppService-backed launch-at-login manager,
/// so we can exercise the enable/disable/error contract the settings UI relies
/// on without touching the real login-item database.
private final class FakeLaunchAtLogin: LaunchAtLoginManaging {
    var enabled: Bool
    var errorToThrow: Error?
    private(set) var setCalls: [Bool] = []

    init(enabled: Bool = false) { self.enabled = enabled }

    var isEnabled: Bool { enabled }

    func setEnabled(_ enabled: Bool) throws {
        setCalls.append(enabled)
        if let errorToThrow { throw errorToThrow }
        self.enabled = enabled
    }
}

private struct DummyError: Error {}

final class SettingsActionsTests: XCTestCase {
    func testLaunchManager_enableThenDisable() throws {
        let fake = FakeLaunchAtLogin(enabled: false)

        try fake.setEnabled(true)
        XCTAssertTrue(fake.isEnabled)

        try fake.setEnabled(false)
        XCTAssertFalse(fake.isEnabled)

        XCTAssertEqual(fake.setCalls, [true, false])
    }

    func testLaunchManager_propagatesErrorAndLeavesStateUnchanged() {
        let fake = FakeLaunchAtLogin(enabled: false)
        fake.errorToThrow = DummyError()

        XCTAssertThrowsError(try fake.setEnabled(true))
        // On failure the state must not flip — the UI reverts the toggle to this.
        XCTAssertFalse(fake.isEnabled)
    }

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
            isLaunchAtLoginEnabled: { fake.isEnabled },
            setLaunchAtLogin: { try fake.setEnabled($0) },
            isDockIconVisible: { dockVisible },
            setDockIconVisible: { dockVisible = $0 },
            isMenuBarIconVisible: { menuBarVisible },
            setMenuBarIconVisible: { menuBarVisible = $0 },
            resetDoubaoCredentials: { doubaoResets += 1 }
        )

        XCTAssertFalse(actions.isLaunchAtLoginEnabled())
        try actions.setLaunchAtLogin(true)
        XCTAssertTrue(actions.isLaunchAtLoginEnabled())

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
