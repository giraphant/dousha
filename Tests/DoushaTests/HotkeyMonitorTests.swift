import XCTest
import CoreGraphics
@testable import Dousha

// @MainActor: the dispatch tests drive HotkeyEventDispatcher, which is @MainActor.
// The pure modifier-mask / whitelist tests are static and run fine on the main actor.
@MainActor
final class HotkeyMonitorTests: XCTestCase {

    // MARK: - keyCode → modifier-bit mapping

    func testModifierMask_isShiftForLeftAndRightShift() {
        XCTAssertEqual(HotkeyMonitor.modifierMask(forKeyCode: 56), .maskShift)  // Left Shift
        XCTAssertEqual(HotkeyMonitor.modifierMask(forKeyCode: 60), .maskShift)  // Right Shift
    }

    func testModifierMask_isCommandForLeftAndRightCommand() {
        XCTAssertEqual(HotkeyMonitor.modifierMask(forKeyCode: 55), .maskCommand) // Left Command
        XCTAssertEqual(HotkeyMonitor.modifierMask(forKeyCode: 54), .maskCommand) // Right Command
    }

    func testModifierMask_isOptionForLeftAndRightOption() {
        XCTAssertEqual(HotkeyMonitor.modifierMask(forKeyCode: 58), .maskAlternate) // Left Option
        XCTAssertEqual(HotkeyMonitor.modifierMask(forKeyCode: 61), .maskAlternate) // Right Option
    }

    func testModifierMask_isControlForLeftAndRightControl() {
        XCTAssertEqual(HotkeyMonitor.modifierMask(forKeyCode: 59), .maskControl) // Left Control
        XCTAssertEqual(HotkeyMonitor.modifierMask(forKeyCode: 62), .maskControl) // Right Control
    }

    func testModifierMask_isSecondaryFnForFn() {
        XCTAssertEqual(HotkeyMonitor.modifierMask(forKeyCode: 63), .maskSecondaryFn) // Fn (Globe)
    }

    func testModifierMask_isNilForNonModifierKey() {
        XCTAssertNil(HotkeyMonitor.modifierMask(forKeyCode: 0))   // 'A'
        XCTAssertNil(HotkeyMonitor.modifierMask(forKeyCode: 105)) // F13
    }

    // MARK: - whitelist / display labels

    func testIsAllowed_returnsTrueForAllWhitelistedKeycodes() {
        for code: UInt16 in [54, 55, 56, 58, 59, 60, 61, 62, 63] {
            XCTAssertTrue(HotkeyMonitor.isAllowed(keyCode: code), "keyCode \(code) should be allowed")
        }
    }

    func testIsAllowed_returnsFalseForNonModifierKeycodes() {
        XCTAssertFalse(HotkeyMonitor.isAllowed(keyCode: 0))
        XCTAssertFalse(HotkeyMonitor.isAllowed(keyCode: 49)) // Space
        XCTAssertFalse(HotkeyMonitor.isAllowed(keyCode: 57)) // Caps Lock — excluded intentionally
    }

    func testDisplayName_isHumanReadable() {
        XCTAssertEqual(HotkeyMonitor.displayName(forKeyCode: 60), "Right Shift")
        XCTAssertEqual(HotkeyMonitor.displayName(forKeyCode: 56), "Left Shift")
        XCTAssertEqual(HotkeyMonitor.displayName(forKeyCode: 63), "Fn (Globe)")
        XCTAssertEqual(HotkeyMonitor.displayName(forKeyCode: 999), "Key 999") // unknown fallback
    }

    // MARK: - mode-aware dispatch

    func testPushToTalk_pressFiresStart_releaseFiresStop() {
        var events: [String] = []
        let dispatcher = HotkeyEventDispatcher(mode: .pushToTalk,
                                               onStart: { events.append("start") },
                                               onStop:  { events.append("stop") })
        dispatcher.handlePress()
        dispatcher.handleRelease()
        XCTAssertEqual(events, ["start", "stop"])
    }

    func testToggle_pressFiresStart_secondPressFiresStop_releaseIgnored() {
        var events: [String] = []
        let dispatcher = HotkeyEventDispatcher(mode: .toggle,
                                               onStart: { events.append("start") },
                                               onStop:  { events.append("stop") })
        dispatcher.handlePress()       // start
        dispatcher.handleRelease()     // ignored in toggle
        dispatcher.handlePress()       // stop
        dispatcher.handleRelease()     // ignored in toggle
        XCTAssertEqual(events, ["start", "stop"])
    }

    func testToggle_doubleStartDoesNotFireTwice() {
        var startCount = 0
        let dispatcher = HotkeyEventDispatcher(mode: .toggle,
                                               onStart: { startCount += 1 },
                                               onStop:  { })
        dispatcher.handlePress()
        dispatcher.handlePress() // second press in toggle mode = stop, not another start
        XCTAssertEqual(startCount, 1)
    }
}
