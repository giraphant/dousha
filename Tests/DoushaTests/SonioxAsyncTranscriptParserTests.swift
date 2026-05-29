import XCTest
import SonioxASR

final class SonioxAsyncTranscriptParserTests: XCTestCase {
    private let parser = SonioxAsyncTranscriptParser()

    func test_concatenatesTokenText() {
        let obj: [String: Any] = [
            "tokens": [
                ["text": "Hello"],
                ["text": " world"]
            ]
        ]
        XCTAssertEqual(parser.parse(object: obj), "Hello world")
    }

    func test_skipsEndMarkerAndTranslationTokens() {
        let obj: [String: Any] = [
            "tokens": [
                ["text": "你好"],
                ["text": "<end>"],
                ["text": "ignored", "translation_status": "translation"],
                ["text": "世界", "translation_status": "original"]
            ]
        ]
        XCTAssertEqual(parser.parse(object: obj), "你好世界")
    }

    func test_fallsBackToTopLevelTextWhenNoTokens() {
        let obj: [String: Any] = ["text": "fallback text"]
        XCTAssertEqual(parser.parse(object: obj), "fallback text")
    }

    func test_fallsBackToTopLevelTextWhenTokensAllSkipped() {
        let obj: [String: Any] = [
            "text": "fallback",
            "tokens": [["text": "<end>"]]
        ]
        XCTAssertEqual(parser.parse(object: obj), "fallback")
    }

    func test_emptyObjectYieldsEmptyString() {
        XCTAssertEqual(parser.parse(object: [:]), "")
    }

    func test_parsesFromJSONData() {
        let json = #"{"tokens":[{"text":"a"},{"text":"b"}]}"#
        XCTAssertEqual(parser.parse(jsonData: Data(json.utf8)), "ab")
    }

    func test_invalidJSONYieldsEmptyString() {
        XCTAssertEqual(parser.parse(jsonData: Data("not json".utf8)), "")
    }
}
