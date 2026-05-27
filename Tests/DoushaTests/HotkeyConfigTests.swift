import XCTest
@testable import Dousha

final class HotkeyConfigTests: XCTestCase {
    func testDefault_isRightShiftPushToTalk() {
        let cfg = HotkeyConfig.default
        XCTAssertEqual(cfg.keyCode, 60) // kVK_RightShift
        XCTAssertEqual(cfg.mode, .pushToTalk)
    }

    func testCodable_roundTrips() throws {
        let original = HotkeyConfig(keyCode: 63, mode: .toggle)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeyConfig.self, from: data)
        XCTAssertEqual(decoded.keyCode, 63)
        XCTAssertEqual(decoded.mode, .toggle)
    }

    func testMode_rawValuesAreStable() {
        // These string raw values are persisted to UserDefaults — renaming
        // them would silently invalidate existing users' configs.
        XCTAssertEqual(HotkeyMode.pushToTalk.rawValue, "pushToTalk")
        XCTAssertEqual(HotkeyMode.toggle.rawValue, "toggle")
    }
}
