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
}
