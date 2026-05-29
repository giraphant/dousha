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

    // MARK: - Glossary (QUA-133) — shared across Doubao + Soniox

    func testGlossaryEnabled_defaultsToDisabled() {
        XCTAssertFalse(prefs.glossaryEnabled)
    }

    func testGlossaryEnabled_persistsAcrossInstances() {
        prefs.glossaryEnabled = true

        let fresh = Preferences(defaults: defaults)

        XCTAssertTrue(fresh.glossaryEnabled)
    }

    func testGlossaryTerms_defaultsToEmpty() {
        XCTAssertEqual(prefs.glossaryTerms, [])
    }

    func testGlossaryTerms_persistsAcrossInstances() {
        prefs.glossaryTerms = ["Anthropic", "Claude", "豆沙"]

        let fresh = Preferences(defaults: defaults)

        XCTAssertEqual(fresh.glossaryTerms, ["Anthropic", "Claude", "豆沙"])
    }

    func testGlossaryTerms_canBeClearedBackToEmpty() {
        prefs.glossaryTerms = ["term"]
        prefs.glossaryTerms = []

        let fresh = Preferences(defaults: defaults)

        XCTAssertEqual(fresh.glossaryTerms, [])
    }

    func testGlossaryTerms_persistUnderHistoricalDoubaoKey() {
        // The UserDefaults key string is still "doubaoGlossaryTerms" so terms
        // entered before the Soniox extension survive the rename.
        prefs.glossaryTerms = ["布迪厄"]
        XCTAssertEqual(defaults.stringArray(forKey: "doubaoGlossaryTerms"), ["布迪厄"])
    }

    func testGlossaryEnabled_persistUnderHistoricalDoubaoKey() {
        prefs.glossaryEnabled = true
        XCTAssertTrue(defaults.bool(forKey: "doubaoGlossaryEnabled"))
    }

    // MARK: - Window/system toggles (QUA-142)

    func testLaunchAtLogin_defaultsToDisabled() {
        XCTAssertFalse(prefs.launchAtLogin)
    }

    func testLaunchAtLogin_persistsAcrossInstances() {
        prefs.launchAtLogin = true

        let fresh = Preferences(defaults: defaults)

        XCTAssertTrue(fresh.launchAtLogin)
    }

    func testShowDockIcon_defaultsToHidden() {
        XCTAssertFalse(prefs.showDockIcon)
    }

    func testShowDockIcon_persistsAcrossInstances() {
        prefs.showDockIcon = true

        let fresh = Preferences(defaults: defaults)

        XCTAssertTrue(fresh.showDockIcon)
    }

    func testShowMenuBarIcon_defaultsToVisible() {
        XCTAssertTrue(prefs.showMenuBarIcon)
    }

    func testShowMenuBarIcon_persistsHiddenAcrossInstances() {
        // Guard against the register-default re-enabling a deliberately hidden
        // status item on restart.
        prefs.showMenuBarIcon = false

        let fresh = Preferences(defaults: defaults)

        XCTAssertFalse(fresh.showMenuBarIcon)
    }
}
