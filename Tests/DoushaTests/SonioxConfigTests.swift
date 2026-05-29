import XCTest
import SonioxASR

final class SonioxConfigTests: XCTestCase {
    private func configObject(apiKey: String) throws -> [String: Any] {
        let json = SonioxConfig.configMessageJSON(apiKey: apiKey)
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return try XCTUnwrap(obj)
    }

    func test_configCarriesRequiredFields() throws {
        let obj = try configObject(apiKey: "secret-key")

        XCTAssertEqual(obj["api_key"] as? String, "secret-key")
        XCTAssertEqual(obj["model"] as? String, "stt-rt-v4")
        XCTAssertEqual(obj["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(obj["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(obj["num_channels"] as? Int, 1)
        XCTAssertEqual(obj["enable_endpoint_detection"] as? Bool, true)
    }

    func test_configOmitsLanguageHintsAndTranslationInAutoMode() throws {
        let obj = try configObject(apiKey: "k")

        XCTAssertNil(obj["language_hints"])
        XCTAssertNil(obj["translation"])
        XCTAssertNil(obj["enable_speaker_diarization"])
        XCTAssertNil(obj["enable_language_identification"])
    }

    func test_constants() {
        XCTAssertEqual(SonioxConfig.endpoint, "wss://stt-rt.soniox.com/transcribe-websocket")
        XCTAssertEqual(SonioxConfig.sampleRate, 16_000)
        XCTAssertEqual(SonioxConfig.channels, 1)
        XCTAssertEqual(SonioxConfig.bytesPerFrame, 640)
    }

    func test_asyncConstants() {
        XCTAssertEqual(SonioxConfig.asyncBaseURL, "https://api.soniox.com")
        XCTAssertEqual(SonioxConfig.asyncModel, "stt-async-v4")
    }

    func test_sonioxModeRawValuesRoundTrip() {
        XCTAssertEqual(SonioxMode(rawValue: "realtime"), .realtime)
        XCTAssertEqual(SonioxMode(rawValue: "async"), .async)
        XCTAssertEqual(SonioxMode.allCases.count, 2)
    }

    func test_keepaliveMessageShape() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(SonioxConfig.keepaliveMessageJSON.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "keepalive")
    }

    // MARK: - Glossary context (QUA-133)

    func test_contextObject_nilWhenNoTerms() {
        XCTAssertNil(SonioxConfig.contextObject(terms: []))
    }

    func test_contextObject_carriesTermsArray() throws {
        let ctx = try XCTUnwrap(SonioxConfig.contextObject(terms: ["布迪厄", "西蒙东"]))
        XCTAssertEqual(ctx["terms"] as? [String], ["布迪厄", "西蒙东"])
    }

    func test_config_omitsContextWhenNoTerms() throws {
        let obj = try configObject(apiKey: "k")
        XCTAssertNil(obj["context"])
    }

    func test_config_carriesContextTermsWhenSet() throws {
        let json = SonioxConfig.configMessageJSON(apiKey: "k", contextTerms: ["布迪厄", "哈贝马斯"])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let ctx = try XCTUnwrap(obj["context"] as? [String: Any])
        XCTAssertEqual(ctx["terms"] as? [String], ["布迪厄", "哈贝马斯"])
        // Required fields still present alongside context.
        XCTAssertEqual(obj["api_key"] as? String, "k")
        XCTAssertEqual(obj["model"] as? String, "stt-rt-v4")
    }

    func test_config_isValidJSONWithContext() {
        let json = SonioxConfig.configMessageJSON(apiKey: "k", contextTerms: ["he said \"hi\"\\x"])
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    // MARK: - Async POST body (QUA-133)

    func test_asyncBody_carriesModelAndFileId() {
        let body = SonioxAsyncClient.transcriptionRequestBody(model: "stt-async-v4", fileId: "f1", contextTerms: [])
        XCTAssertEqual(body["model"] as? String, "stt-async-v4")
        XCTAssertEqual(body["file_id"] as? String, "f1")
    }

    func test_asyncBody_omitsContextWhenNoTerms() {
        let body = SonioxAsyncClient.transcriptionRequestBody(model: "m", fileId: "f", contextTerms: [])
        XCTAssertNil(body["context"])
    }

    func test_asyncBody_carriesContextTermsWhenSet() throws {
        let body = SonioxAsyncClient.transcriptionRequestBody(model: "m", fileId: "f", contextTerms: ["布迪厄", "许煜"])
        let ctx = try XCTUnwrap(body["context"] as? [String: Any])
        XCTAssertEqual(ctx["terms"] as? [String], ["布迪厄", "许煜"])
    }
}
