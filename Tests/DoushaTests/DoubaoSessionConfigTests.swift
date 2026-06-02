import XCTest
@testable import DoubaoASR

final class DoubaoSessionConfigTests: XCTestCase {
    private func extra(_ json: String) throws -> [String: Any] {
        let data = json.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return obj["extra"] as! [String: Any]
    }

    func testOutputIsValidJSON() {
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "甲、乙")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: json.data(using: .utf8)!))
    }

    func testContextCarriesHintWhenSet() throws {
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "甲、乙、丙")
        let extra = try extra(json)
        XCTAssertEqual(extra["context"] as? String, "甲、乙、丙")
    }

    func testContextIsEmptyStringWhenHintEmpty() throws {
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "")
        let extra = try extra(json)
        // Key is always present (schema-stable), empty when no hint.
        XCTAssertEqual(extra["context"] as? String, "")
    }

    func testContextKeyAlwaysPresent() throws {
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "")
        let extra = try extra(json)
        XCTAssertNotNil(extra["context"])
    }

    func testDeviceIdEmbedded() throws {
        let json = buildSessionConfigJSON(deviceId: "device-xyz", contextHint: "")
        let extra = try extra(json)
        XCTAssertEqual(extra["did"] as? String, "device-xyz")
    }

    func testExistingKnobsUnchanged() throws {
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x")
        let extra = try extra(json)
        XCTAssertEqual(extra["strong_ddc"] as? Bool, true)
        XCTAssertEqual(extra["use_twopass_retry"] as? Bool, true)
        XCTAssertEqual(extra["end_smooth_window_ms"] as? Int, 800)
        XCTAssertEqual(extra["input_mode"] as? String, "tool")
    }

    func testContextWithJSONSpecialCharsIsEscaped() throws {
        // A term with quotes/backslashes must round-trip via JSONSerialization,
        // proving we never hand-interpolate the context into the JSON.
        let tricky = "he said \"hi\"\\path、x"
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: tricky)
        let extra = try extra(json)
        XCTAssertEqual(extra["context"] as? String, tricky)
    }

    func testOfficialProfileMatchesCurrentKnobs() throws {
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .official)
        let extra = try extra(json)

        XCTAssertEqual(extra["enable_asr_threepass"] as? Bool, true)
        XCTAssertEqual(extra["enable_asr_twopass"] as? Bool, true)
        XCTAssertEqual(extra["strong_ddc"] as? Bool, true)
        XCTAssertEqual(extra["use_twopass_retry"] as? Bool, true)
        XCTAssertEqual(extra["end_smooth_window_ms"] as? Int, 800)
    }

    func testFastProfileDisablesMostLikelyTailLatencyKnobs() throws {
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .fast)
        let extra = try extra(json)

        XCTAssertEqual(extra["enable_asr_threepass"] as? Bool, false)
        XCTAssertEqual(extra["enable_asr_twopass"] as? Bool, true)
        XCTAssertEqual(extra["strong_ddc"] as? Bool, true)
        XCTAssertEqual(extra["use_twopass_retry"] as? Bool, false)
        XCTAssertEqual(extra["end_smooth_window_ms"] as? Int, 800)
    }

    func testMinimalProfileUsesLowestLatencyKnobs() throws {
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .minimal)
        let extra = try extra(json)

        XCTAssertEqual(extra["enable_asr_threepass"] as? Bool, false)
        XCTAssertEqual(extra["enable_asr_twopass"] as? Bool, false)
        XCTAssertEqual(extra["strong_ddc"] as? Bool, false)
        XCTAssertEqual(extra["use_twopass_retry"] as? Bool, false)
        XCTAssertEqual(extra["end_smooth_window_ms"] as? Int, 400)
    }

    func testProfileInitFallsBackToOfficialForUnknownRawValue() {
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "unknown"), .official)
    }

    func testProfileInitAcceptsCaseInsensitiveValues() {
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "FAST"), .fast)
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: " minimal "), .minimal)
    }

    func testResolvedProfilePrefersEnvironmentOverUserDefaults() {
        let defaults = UserDefaults(suiteName: "DoubaoSessionConfigTests-env")!
        defaults.set("minimal", forKey: DoubaoExperimentProfile.userDefaultsKey)

        let profile = DoubaoExperimentProfile.resolve(
            environment: [DoubaoExperimentProfile.environmentKey: "fast"],
            defaults: defaults
        )

        XCTAssertEqual(profile, .fast)
        defaults.removePersistentDomain(forName: "DoubaoSessionConfigTests-env")
    }

    func testResolvedProfileUsesUserDefaultsWhenEnvironmentMissing() {
        let defaults = UserDefaults(suiteName: "DoubaoSessionConfigTests-ud")!
        defaults.set("minimal", forKey: DoubaoExperimentProfile.userDefaultsKey)

        let profile = DoubaoExperimentProfile.resolve(environment: [:], defaults: defaults)

        XCTAssertEqual(profile, .minimal)
        defaults.removePersistentDomain(forName: "DoubaoSessionConfigTests-ud")
    }
}
