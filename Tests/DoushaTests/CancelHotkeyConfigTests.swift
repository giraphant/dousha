import XCTest
@testable import Dousha

final class CancelHotkeyConfigTests: XCTestCase {

    // MARK: - defaults and constants

    func testDefault_isEsc() {
        let cfg = CancelHotkeyConfig.default
        XCTAssertEqual(cfg.keyCode, CancelHotkeyConfig.escKeyCode)
        XCTAssertEqual(cfg.keyCode, 53)
        XCTAssertTrue(cfg.isEnabled)
    }

    func testDisabled_hasNoKeycodeAndReportsDisabled() {
        let cfg = CancelHotkeyConfig.disabled
        XCTAssertNil(cfg.keyCode)
        XCTAssertFalse(cfg.isEnabled)
        XCTAssertEqual(cfg.displayName, "Off")
    }

    // MARK: - displayName mapping

    func testDisplayName_isEscForKeyCode53() {
        XCTAssertEqual(CancelHotkeyConfig.displayName(forKeyCode: 53), "Esc")
        XCTAssertEqual(CancelHotkeyConfig(keyCode: 53).displayName, "Esc")
    }

    func testDisplayName_coversCommonNonAlphanumerics() {
        XCTAssertEqual(CancelHotkeyConfig.displayName(forKeyCode: 49),  "Space")
        XCTAssertEqual(CancelHotkeyConfig.displayName(forKeyCode: 36),  "Return")
        XCTAssertEqual(CancelHotkeyConfig.displayName(forKeyCode: 48),  "Tab")
        XCTAssertEqual(CancelHotkeyConfig.displayName(forKeyCode: 51),  "Delete")
        XCTAssertEqual(CancelHotkeyConfig.displayName(forKeyCode: 122), "F1")
        XCTAssertEqual(CancelHotkeyConfig.displayName(forKeyCode: 111), "F12")
    }

    func testDisplayName_unknownFallsBackToKeyN() {
        XCTAssertEqual(CancelHotkeyConfig.displayName(forKeyCode: 999), "Key 999")
    }

    // MARK: - Codable

    func testCodable_roundTripsEnabledAndDisabled() throws {
        // Enabled — keyCode is preserved across encode/decode.
        let enabled = CancelHotkeyConfig(keyCode: 122) // F1
        let enabledData = try JSONEncoder().encode(enabled)
        let enabledDecoded = try JSONDecoder().decode(CancelHotkeyConfig.self, from: enabledData)
        XCTAssertEqual(enabledDecoded.keyCode, 122)
        XCTAssertTrue(enabledDecoded.isEnabled)

        // Disabled — round trip preserves nil keyCode.
        let disabled = CancelHotkeyConfig.disabled
        let disabledData = try JSONEncoder().encode(disabled)
        let disabledDecoded = try JSONDecoder().decode(CancelHotkeyConfig.self, from: disabledData)
        XCTAssertNil(disabledDecoded.keyCode)
        XCTAssertFalse(disabledDecoded.isEnabled)
    }
}
