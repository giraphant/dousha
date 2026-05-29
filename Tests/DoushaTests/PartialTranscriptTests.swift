import XCTest
import ASRSupport

final class PartialTranscriptTests: XCTestCase {
    func testCombinedConcatenatesFinalThenInterim() {
        let p = PartialTranscript(finalText: "你好", interimText: "世界")
        XCTAssertEqual(p.combined, "你好世界")
    }

    func testEmptyHasEmptyCombined() {
        XCTAssertEqual(PartialTranscript.empty.combined, "")
        XCTAssertEqual(PartialTranscript.empty.finalText, "")
        XCTAssertEqual(PartialTranscript.empty.interimText, "")
    }

    func testEquatable() {
        XCTAssertEqual(PartialTranscript(finalText: "a", interimText: "b"),
                       PartialTranscript(finalText: "a", interimText: "b"))
        XCTAssertNotEqual(PartialTranscript(finalText: "a", interimText: "b"),
                          PartialTranscript(finalText: "a", interimText: "c"))
    }
}
