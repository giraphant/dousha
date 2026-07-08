import XCTest
@testable import DoubaoASR

final class DoubaoSessionConfigTests: XCTestCase {
    private let speakerExperimentKeys = [
        "enable_speaker_diarization",
        "sos_silence_timeout",
        "eos_silence_timeout",
        "sentence_max_time"
    ]

    private func object(_ json: String) throws -> [String: Any] {
        let data = json.data(using: .utf8)!
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func extra(_ json: String) throws -> [String: Any] {
        let obj = try object(json)
        return obj["extra"] as! [String: Any]
    }

    private func assertSpeakerPayload(_ payload: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(payload["enable_speaker_diarization"] as? Bool, true, file: file, line: line)
        XCTAssertEqual(payload["sos_silence_timeout"] as? Int, 800, file: file, line: line)
        XCTAssertEqual(payload["eos_silence_timeout"] as? Int, 800, file: file, line: line)
        XCTAssertEqual(payload["sentence_max_time"] as? Int, 10_000, file: file, line: line)
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

    func testOfficialProfileDoesNotEmitSpeakerExperimentKeys() throws {
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .official)
        let obj = try object(json)
        let extra = obj["extra"] as! [String: Any]

        for key in speakerExperimentKeys {
            XCTAssertNil(obj[key])
            XCTAssertNil(extra[key])
        }
        XCTAssertNil(extra["asr_params"])
    }

    func testSpeakerFlatProfileEmitsExperimentKeysInExtra() throws {
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .speakerFlat)
        let obj = try object(json)
        let extra = obj["extra"] as! [String: Any]

        assertSpeakerPayload(extra)
        for key in speakerExperimentKeys {
            XCTAssertNil(obj[key])
        }
        XCTAssertNil(extra["asr_params"])
    }

    func testSpeakerNestedProfileEmitsExperimentKeysUnderAsrParams() throws {
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .speakerNested)
        let obj = try object(json)
        let extra = obj["extra"] as! [String: Any]
        let asrParams = extra["asr_params"] as! [String: Any]

        assertSpeakerPayload(asrParams)
        for key in speakerExperimentKeys {
            XCTAssertNil(obj[key])
            XCTAssertNil(extra[key])
        }
    }

    func testSpeakerTopProfileEmitsExperimentKeysAtTopLevel() throws {
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .speakerTop)
        let obj = try object(json)
        let extra = obj["extra"] as! [String: Any]

        assertSpeakerPayload(obj)
        for key in speakerExperimentKeys {
            XCTAssertNil(extra[key])
        }
        XCTAssertNil(extra["asr_params"])
    }

    func testSpeakerProfilesPreservePausePunctuationKnobs() throws {
        for profile in [DoubaoExperimentProfile.speakerFlat, .speakerNested, .speakerNestedBare, .speakerNestedString, .speakerNestedSeconds, .speakerTop, .speechReject, .asrSplit, .asrSplitDiar, .asrGlobalTracking, .asrTextFilter, .asrForceTwopass] {
            let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: profile)
            let extra = try extra(json)

            XCTAssertEqual(extra["enable_vad_timeout_break"] as? Bool, false)
            XCTAssertEqual(extra["no_repeat_ngram_size"] as? Int, 6)
            XCTAssertEqual(extra["max_indefinite_utterance"] as? Int, 1)
            XCTAssertEqual(extra["enable_text_post_process"] as? Bool, true)
            XCTAssertEqual(extra["asr_text_post_process_type"] as? String, "last_post_process")
        }
    }

    func testProfileInitFallsBackToOfficialForUnknownRawValue() {
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "unknown"), .official)
    }

    func testProfileInitAcceptsCaseInsensitiveValues() {
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "FAST"), .fast)
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: " minimal "), .minimal)
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: " SPEAKER-FLAT "), .speakerFlat)
    }

    func testProfileInitAcceptsUnderscoreSpeakerProfileAlias() {
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "speaker_flat"), .speakerFlat)
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "speaker_nested"), .speakerNested)
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "speaker_nested_bare"), .speakerNestedBare)
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "speaker_nested_string"), .speakerNestedString)
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "speaker_nested_seconds"), .speakerNestedSeconds)
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "speaker_top"), .speakerTop)
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "speech_reject"), .speechReject)
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "asr_split"), .asrSplit)
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "asr_split_diar"), .asrSplitDiar)
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "asr_global_tracking"), .asrGlobalTracking)
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "asr_text_filter"), .asrTextFilter)
        XCTAssertEqual(DoubaoExperimentProfile(rawExperimentValue: "asr_force_twopass"), .asrForceTwopass)
    }

    func testSpeakerNestedBareProfileOnlyEmitsDiarizationFlag() throws {
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .speakerNestedBare)
        let obj = try object(json)
        let extra = obj["extra"] as! [String: Any]
        let asrParams = extra["asr_params"] as! [String: Any]

        XCTAssertEqual(asrParams.count, 1)
        XCTAssertEqual(asrParams["enable_speaker_diarization"] as? Bool, true)
        XCTAssertNil(obj["enable_speaker_diarization"])
        XCTAssertNil(extra["enable_speaker_diarization"])
    }

    func testSpeakerNestedStringProfileUsesStringBoolean() throws {
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .speakerNestedString)
        let extra = try extra(json)
        let asrParams = extra["asr_params"] as! [String: Any]

        XCTAssertEqual(asrParams.count, 1)
        XCTAssertEqual(asrParams["enable_speaker_diarization"] as? String, "true")
    }

    func testSpeakerNestedSecondsProfileUsesMacSecondsKey() throws {
        let json = buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .speakerNestedSeconds)
        let obj = try object(json)
        let extra = obj["extra"] as! [String: Any]
        let asrParams = extra["asr_params"] as! [String: Any]

        XCTAssertEqual(asrParams.count, 4)
        XCTAssertEqual(asrParams["enable_speaker_diarization"] as? Bool, true)
        XCTAssertEqual(asrParams["sos_silence_timeout"] as? Int, 800)
        XCTAssertEqual(asrParams["eos_silence_timeout"] as? Int, 800)
        XCTAssertEqual(asrParams["sentence_max_seconds"] as? Int, 10)
        XCTAssertNil(asrParams["sentence_max_time"])
        XCTAssertNil(obj["sentence_max_seconds"])
        XCTAssertNil(extra["sentence_max_seconds"])
    }

    func testSpeechRejectProfileOnlyChangesTopLevelSpeechRejection() throws {
        let official = try object(buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .official))
        let reject = try object(buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .speechReject))
        let extra = reject["extra"] as! [String: Any]

        XCTAssertEqual(official["enable_speech_rejection"] as? Bool, false)
        XCTAssertEqual(reject["enable_speech_rejection"] as? Bool, true)
        XCTAssertNil(extra["asr_params"])
        for key in speakerExperimentKeys {
            XCTAssertNil(reject[key])
            XCTAssertNil(extra[key])
        }
    }

    func testAsrSplitProfileEmitsNestedSplitFlag() throws {
        let extra = try extra(buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .asrSplit))
        let asrParams = extra["asr_params"] as! [String: Any]

        XCTAssertEqual(asrParams.count, 1)
        XCTAssertEqual(asrParams["enable_split"] as? Bool, true)
    }

    func testAsrSplitDiarProfileCombinesSplitAndDiarization() throws {
        let extra = try extra(buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: .asrSplitDiar))
        let asrParams = extra["asr_params"] as! [String: Any]

        XCTAssertEqual(asrParams.count, 2)
        XCTAssertEqual(asrParams["enable_split"] as? Bool, true)
        XCTAssertEqual(asrParams["enable_speaker_diarization"] as? Bool, true)
    }

    func testOtherAsrParamsProfilesEmitSingleNestedFlag() throws {
        let cases: [(DoubaoExperimentProfile, String)] = [
            (.asrGlobalTracking, "enable_global_tracking"),
            (.asrTextFilter, "enable_text_filter"),
            (.asrForceTwopass, "force_asr_twopass")
        ]

        for (profile, key) in cases {
            let extra = try extra(buildSessionConfigJSON(deviceId: "dev-1", contextHint: "x", profile: profile))
            let asrParams = extra["asr_params"] as! [String: Any]

            XCTAssertEqual(asrParams.count, 1)
            XCTAssertEqual(asrParams[key] as? Bool, true)
        }
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

    func testResolvedProfileCanUseSpeakerProfileFromEnvironment() {
        let defaults = UserDefaults(suiteName: "DoubaoSessionConfigTests-speaker-env")!
        defaults.set("minimal", forKey: DoubaoExperimentProfile.userDefaultsKey)

        let profile = DoubaoExperimentProfile.resolve(
            environment: [DoubaoExperimentProfile.environmentKey: "speaker-nested"],
            defaults: defaults
        )

        XCTAssertEqual(profile, .speakerNested)
        defaults.removePersistentDomain(forName: "DoubaoSessionConfigTests-speaker-env")
    }
}
