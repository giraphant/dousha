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

    func testRefineModeRoundTrips() {
        let suiteName = "PreferencesTests.refineMode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let prefs = Preferences(defaults: defaults)

        // Default is Immediate (preserves today's behaviour when LLM is on).
        XCTAssertEqual(prefs.refineMode, .immediate)

        prefs.refineMode = .deferred
        XCTAssertEqual(prefs.refineMode, .deferred)

        // Survives a fresh Preferences over the same defaults.
        let prefs2 = Preferences(defaults: defaults)
        XCTAssertEqual(prefs2.refineMode, .deferred)
    }

    // MARK: - Multi-engine routing (QUA-145)

    func testEngineSlots_defaultToLegacyApple() {
        XCTAssertEqual(prefs.chineseEngine, .apple)
        XCTAssertEqual(prefs.englishEngine, .apple)
        XCTAssertEqual(prefs.mixedEngine, .apple)
        XCTAssertEqual(prefs.activeEngines, [.apple])
    }

    func testEngineSlots_ignoreRetiredLegacyEngineKey() {
        // The pre-QUA-145 single `engine` key has been retired. A stale value
        // left in storage must NOT seed the routing slots anymore — unset slots
        // fall back to the baseline default (apple).
        defaults.set(Engine.soniox.rawValue, forKey: "engine")
        let p = Preferences(defaults: defaults)
        XCTAssertEqual(p.chineseEngine, .apple)
        XCTAssertEqual(p.englishEngine, .apple)
        XCTAssertEqual(p.mixedEngine, .apple)
        XCTAssertEqual(p.activeEngines, [.apple])
    }

    func testPrimaryEngine_followsLanguageSlots() {
        prefs.chineseEngine = .doubao
        prefs.englishEngine = .soniox
        prefs.mixedEngine = .soniox
        XCTAssertEqual(prefs.primaryEngine(forLanguage: "zh-CN"), .doubao)
        XCTAssertEqual(prefs.primaryEngine(forLanguage: "en-US"), .soniox)
        XCTAssertEqual(prefs.primaryEngine(forLanguage: "ja-JP"), .soniox) // catch-all → mixed
    }

    func testEngineComputed_getIsPrimaryForLanguage() {
        prefs.chineseEngine = .doubao
        prefs.englishEngine = .soniox
        prefs.mixedEngine = .soniox
        prefs.language = "zh-CN"
        XCTAssertEqual(prefs.engine, .doubao)
        prefs.language = "en-US"
        XCTAssertEqual(prefs.engine, .soniox)
    }

    func testSetSingleEngine_collapsesSlotsAndActive() {
        prefs.chineseEngine = .doubao
        prefs.englishEngine = .soniox
        prefs.setSingleEngine(.apple)
        XCTAssertEqual(prefs.chineseEngine, .apple)
        XCTAssertEqual(prefs.englishEngine, .apple)
        XCTAssertEqual(prefs.mixedEngine, .apple)
        XCTAssertEqual(prefs.activeEngines, [.apple])
    }

    func testEngineSetter_switchesToSingleEngineMode() {
        prefs.engine = .doubao
        XCTAssertEqual(prefs.activeEngines, [.doubao])
        XCTAssertEqual(prefs.chineseEngine, .doubao)
        XCTAssertEqual(prefs.mixedEngine, .doubao)
    }

    func testActiveEngines_persistDedupAndNonEmpty() {
        prefs.activeEngines = [.doubao, .soniox, .doubao]
        XCTAssertEqual(Preferences(defaults: defaults).activeEngines, [.doubao, .soniox])
        prefs.activeEngines = []
        XCTAssertFalse(Preferences(defaults: defaults).activeEngines.isEmpty)
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

    // MARK: - Audio processing

    func testVoiceProcessing_defaultsToDisabled() {
        XCTAssertFalse(prefs.voiceProcessingEnabled)
    }

    func testVoiceProcessing_ignoresStaleEnabledValue() {
        defaults.set(true, forKey: "voiceProcessingEnabled")

        let fresh = Preferences(defaults: defaults)

        XCTAssertFalse(fresh.voiceProcessingEnabled)
    }

    func testMicrophoneSelection_defaultsToSystemDefault() {
        XCTAssertEqual(prefs.microphoneSelection, .systemDefault)
    }

    func testMicrophoneSelection_persistsPriorityListAcrossInstances() {
        prefs.microphoneSelection = MicrophoneSelectionPreference(
            useSystemDefault: false,
            priorityUIDs: ["builtin", "usb"]
        )

        let fresh = Preferences(defaults: defaults)

        XCTAssertEqual(fresh.microphoneSelection,
                       MicrophoneSelectionPreference(useSystemDefault: false,
                                                     priorityUIDs: ["builtin", "usb"]))
    }

    func testRecordingAudioControls_defaultMuteButDoNotPauseMedia() {
        XCTAssertTrue(prefs.muteSystemAudioDuringRecording)
        XCTAssertFalse(prefs.pauseMediaDuringRecording)
    }

    func testRecordingAudioControls_persistAcrossInstances() {
        prefs.muteSystemAudioDuringRecording = false
        prefs.pauseMediaDuringRecording = true

        let fresh = Preferences(defaults: defaults)

        XCTAssertFalse(fresh.muteSystemAudioDuringRecording)
        XCTAssertTrue(fresh.pauseMediaDuringRecording)
    }
}
