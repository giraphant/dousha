import XCTest
@testable import Dousha

final class CancelHotkeyPreferencesTests: XCTestCase {
    // Ephemeral suite per test so we don't pollute the user's real defaults.
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var prefs: Preferences!

    override func setUp() {
        super.setUp()
        suiteName = "DoushaTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        prefs = Preferences(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testCancelHotkey_defaultsToEsc() {
        XCTAssertEqual(prefs.cancelHotkey.keyCode, CancelHotkeyConfig.escKeyCode)
        XCTAssertTrue(prefs.cancelHotkey.isEnabled)
    }

    func testCancelHotkey_persistsEnabledChangeAcrossInstances() {
        // Bind F1 as the cancel key.
        prefs.cancelHotkey = CancelHotkeyConfig(keyCode: 122)
        let fresh = Preferences(defaults: defaults)
        XCTAssertEqual(fresh.cancelHotkey.keyCode, 122)
        XCTAssertTrue(fresh.cancelHotkey.isEnabled)
    }

    func testCancelHotkey_persistsDisabledStateAcrossInstances() {
        // The disabled state is the load-bearing edge case: if storage round-trips
        // it as the default Esc instead of nil, the user's "Off" choice silently
        // re-enables cancel after a restart.
        prefs.cancelHotkey = .disabled
        let fresh = Preferences(defaults: defaults)
        XCTAssertNil(fresh.cancelHotkey.keyCode)
        XCTAssertFalse(fresh.cancelHotkey.isEnabled)
    }

    func testCancelHotkey_canBeReenabledAfterDisabling() {
        prefs.cancelHotkey = .disabled
        prefs.cancelHotkey = CancelHotkeyConfig(keyCode: 53)
        let fresh = Preferences(defaults: defaults)
        XCTAssertEqual(fresh.cancelHotkey.keyCode, 53)
        XCTAssertTrue(fresh.cancelHotkey.isEnabled)
    }

    func testCancelHotkey_explicitKeycodeZeroIsPreserved() {
        // Regression guard: `defaults.integer(forKey:)` returns 0 for both
        // "unset" and "explicitly set to 0". The getter must distinguish these
        // via `defaults.object(forKey:)`. If we ever silently round-trip an
        // explicit 0 back through the default Esc, users who bound cancel to
        // 'A' (keycode 0) would lose their setting on every restart.
        prefs.cancelHotkey = CancelHotkeyConfig(keyCode: 0)
        let fresh = Preferences(defaults: defaults)
        XCTAssertEqual(fresh.cancelHotkey.keyCode, 0)
        XCTAssertTrue(fresh.cancelHotkey.isEnabled)
    }
}
