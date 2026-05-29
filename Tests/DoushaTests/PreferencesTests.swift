import XCTest
import SonioxASR
@testable import Dousha

final class PreferencesTests: XCTestCase {
    // Use an ephemeral suite so we don't pollute the user's real defaults.
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

    func testHotkey_defaultsToRightShiftPushToTalk() {
        XCTAssertEqual(prefs.hotkey.keyCode, 60)
        XCTAssertEqual(prefs.hotkey.mode, .pushToTalk)
    }

    func testHotkey_persistsAcrossInstances() {
        prefs.hotkey = HotkeyConfig(keyCode: 63, mode: .toggle)
        let fresh = Preferences(defaults: defaults)
        XCTAssertEqual(fresh.hotkey.keyCode, 63)
        XCTAssertEqual(fresh.hotkey.mode, .toggle)
    }

    func testSmartRetranscribe_defaultsToDisabled() {
        XCTAssertFalse(prefs.smartRetranscribeEnabled)
    }

    func testSmartRetranscribe_persistsDisabledAcrossInstances() {
        prefs.smartRetranscribeEnabled = false

        let fresh = Preferences(defaults: defaults)

        XCTAssertFalse(fresh.smartRetranscribeEnabled)
    }

    func testSmartRetranscribe_canBeReenabledAfterDisabling() {
        prefs.smartRetranscribeEnabled = false
        prefs.smartRetranscribeEnabled = true

        let fresh = Preferences(defaults: defaults)

        XCTAssertTrue(fresh.smartRetranscribeEnabled)
    }

    func testSonioxAPIKey_defaultsToEmpty() {
        XCTAssertEqual(prefs.sonioxAPIKey, "")
    }

    func testSonioxAPIKey_persistsAcrossInstances() {
        prefs.sonioxAPIKey = "soniox-secret"

        let fresh = Preferences(defaults: defaults)

        XCTAssertEqual(fresh.sonioxAPIKey, "soniox-secret")
    }

    func testSonioxMode_defaultsToRealtime() {
        XCTAssertEqual(prefs.sonioxMode, .realtime)
    }

    func testSonioxMode_persistsAsyncAcrossInstances() {
        prefs.sonioxMode = .async

        let fresh = Preferences(defaults: defaults)

        XCTAssertEqual(fresh.sonioxMode, .async)
    }

    func testSonioxMode_canSwitchBackToRealtime() {
        prefs.sonioxMode = .async
        prefs.sonioxMode = .realtime

        let fresh = Preferences(defaults: defaults)

        XCTAssertEqual(fresh.sonioxMode, .realtime)
    }
}
