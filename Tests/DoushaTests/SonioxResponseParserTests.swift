import XCTest
import SonioxASR

final class SonioxResponseParserTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func test_finalTokensAccumulateAcrossBatches() {
        var parser = SonioxResponseParser()
        parser.ingest(jsonData: data(#"{"tokens":[{"text":"Hello","is_final":true}]}"#))
        parser.ingest(jsonData: data(#"{"tokens":[{"text":" world","is_final":true}]}"#))

        XCTAssertEqual(parser.finalText, "Hello world")
        XCTAssertEqual(parser.displayText, "Hello world")
    }

    func test_interimIsReplacedNotAccumulated() {
        var parser = SonioxResponseParser()
        parser.ingest(jsonData: data(#"{"tokens":[{"text":"par","is_final":false}]}"#))
        parser.ingest(jsonData: data(#"{"tokens":[{"text":"partial","is_final":false}]}"#))

        XCTAssertEqual(parser.finalText, "")
        XCTAssertEqual(parser.interimText, "partial")
        XCTAssertEqual(parser.displayText, "partial")
    }

    func test_finalPlusInterimComposeDisplayText() {
        var parser = SonioxResponseParser()
        parser.ingest(jsonData: data(#"{"tokens":[{"text":"Hello ","is_final":true},{"text":"wor","is_final":false}]}"#))

        XCTAssertEqual(parser.finalText, "Hello ")
        XCTAssertEqual(parser.interimText, "wor")
        XCTAssertEqual(parser.displayText, "Hello wor")
    }

    func test_endMarkerFlushesInterimAndIsNeverAppended() {
        var parser = SonioxResponseParser()
        parser.ingest(jsonData: data(#"{"tokens":[{"text":"hi","is_final":false}]}"#))
        parser.ingest(jsonData: data(#"{"tokens":[{"text":"hi","is_final":true},{"text":"<end>","is_final":true}]}"#))

        XCTAssertEqual(parser.finalText, "hi")
        XCTAssertEqual(parser.interimText, "")
        XCTAssertFalse(parser.displayText.contains("<end>"))
    }

    func test_finishedDetectedEvenWithEmptyTokens() {
        var parser = SonioxResponseParser()
        let update = parser.ingest(jsonData: data(#"{"tokens":[],"finished":true}"#))

        XCTAssertEqual(update?.finished, true)
        XCTAssertTrue(parser.isFinished)
    }

    func test_finishedFlagSurfacedInUpdate() {
        var parser = SonioxResponseParser()
        let update = parser.ingest(jsonData: data(#"{"tokens":[{"text":"done","is_final":true}],"finished":true}"#))

        XCTAssertEqual(update?.finished, true)
        XCTAssertEqual(parser.finalText, "done")
    }

    func test_errorMessageExtracted() {
        var parser = SonioxResponseParser()
        let update = parser.ingest(jsonData: data(#"{"error_code":401,"error_message":"Invalid API key"}"#))

        XCTAssertEqual(update?.errorMessage, "Invalid API key")
        XCTAssertEqual(parser.errorMessage, "Invalid API key")
    }

    func test_missingTranslationStatusTreatedAsOriginalText() {
        var parser = SonioxResponseParser()
        parser.ingest(jsonData: data(#"{"tokens":[{"text":"plain","is_final":true}]}"#))

        XCTAssertEqual(parser.finalText, "plain")
    }

    func test_noneTranslationStatusTreatedAsText() {
        var parser = SonioxResponseParser()
        parser.ingest(jsonData: data(#"{"tokens":[{"text":"x","is_final":true,"translation_status":"none"}]}"#))

        XCTAssertEqual(parser.finalText, "x")
    }

    func test_translationTokensAreIgnored() {
        var parser = SonioxResponseParser()
        parser.ingest(jsonData: data(#"{"tokens":[{"text":"orig","is_final":true,"translation_status":"original"},{"text":"trans","is_final":true,"translation_status":"translation"}]}"#))

        XCTAssertEqual(parser.finalText, "orig")
    }

    func test_invalidJSONReturnsNil() {
        var parser = SonioxResponseParser()
        XCTAssertNil(parser.ingest(jsonData: data("not json")))
    }

    func test_multiResponseSequenceBuildsTranscript() {
        var parser = SonioxResponseParser()
        parser.ingest(jsonData: data(#"{"tokens":[{"text":"The ","is_final":true},{"text":"qui","is_final":false}]}"#))
        parser.ingest(jsonData: data(#"{"tokens":[{"text":"quick ","is_final":true},{"text":"bro","is_final":false}]}"#))
        parser.ingest(jsonData: data(#"{"tokens":[{"text":"brown fox","is_final":true},{"text":"<end>","is_final":true}],"finished":true}"#))

        XCTAssertEqual(parser.finalText, "The quick brown fox")
        XCTAssertEqual(parser.interimText, "")
        XCTAssertTrue(parser.isFinished)
    }

    func testUpdateCarriesFinalAndInterimSplit() {
        var parser = SonioxResponseParser()
        // Batch 1: one final token + one interim token.
        let u1 = parser.ingest(jsonData: data(#"{"tokens":[{"text":"你好","is_final":true},{"text":"世界","is_final":false}]}"#))
        XCTAssertEqual(u1?.finalText, "你好")
        XCTAssertEqual(u1?.interimText, "世界")
        XCTAssertEqual(u1?.displayText, "你好世界")

        // Batch 2: interim replaced, no new final.
        let u2 = parser.ingest(jsonData: data(#"{"tokens":[{"text":"朋友","is_final":false}]}"#))
        XCTAssertEqual(u2?.finalText, "你好")
        XCTAssertEqual(u2?.interimText, "朋友")
    }
}
