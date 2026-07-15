import XCTest
import ASRSupport
import DoubaoASR

final class DoubaoResultStateTests: XCTestCase {
    private func response(_ result: String) -> String {
        "{\"results\":[\(result)]}"
    }

    func testInterimIsReplaced() {
        var state = DoubaoResultState()
        state.ingest(resultJson: response(#"{"text":"par","is_interim":true}"#))
        state.ingest(resultJson: response(#"{"text":"partial","is_interim":true}"#))

        XCTAssertEqual(state.finalText, "")
        XCTAssertEqual(state.interimText, "partial")
    }

    func testVadFinalCommitsSegment() {
        var state = DoubaoResultState()
        let update = state.ingest(resultJson: response(#"{"text":"first","is_interim":false,"is_vad_finished":true}"#))

        XCTAssertEqual(update?.commit, .final("first"))
        XCTAssertEqual(update?.partial, PartialTranscript(finalText: "first", interimText: ""))
        XCTAssertEqual(state.rawText, "first")
    }

    func testNonstreamResultCommitsWithoutVadFinal() {
        var state = DoubaoResultState()
        let update = state.ingest(resultJson: response(#"{"text":"offline","is_interim":true,"extra":{"nonstream_result":true}}"#))

        XCTAssertEqual(update?.commit, .final("offline"))
        XCTAssertEqual(state.committedSegments, ["offline"])
        XCTAssertEqual(state.interimText, "")
    }

    func testShortNewUtteranceRescuesPreviousInterim() {
        var state = DoubaoResultState()
        state.ingest(resultJson: response(#"{"text":"this is a much longer first utterance","is_interim":true}"#))
        let update = state.ingest(resultJson: response(#"{"text":"next","is_interim":true}"#))

        XCTAssertEqual(update?.commit, .rescued("this is a much longer first utterance"))
        XCTAssertEqual(state.committedSegments, ["this is a much longer first utterance"])
        XCTAssertEqual(state.interimText, "next")
    }

    func testInvalidAndHeartbeatPayloadsAreIgnored() {
        var state = DoubaoResultState()

        XCTAssertNil(state.ingest(resultJson: "not json"))
        XCTAssertNil(state.ingest(resultJson: #"{"results":[]}"#))
        XCTAssertEqual(state.rawText, "")
    }
}
