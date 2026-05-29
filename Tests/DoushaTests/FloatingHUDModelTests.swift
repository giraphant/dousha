import XCTest
import ASRSupport
@testable import Dousha

final class FloatingHUDModelTests: XCTestCase {
    @MainActor
    func testStartsEmptyWithNoTranscript() {
        let m = FloatingHUDModel()
        XCTAssertFalse(m.hasTranscript)
        XCTAssertEqual(m.transcript, .empty)
    }

    @MainActor
    func testUpdateTranscriptStoresFinalAndInterim() {
        let m = FloatingHUDModel()
        m.updateTranscript(PartialTranscript(finalText: "你好", interimText: "世界"))
        XCTAssertTrue(m.hasTranscript)
        XCTAssertEqual(m.transcript.finalText, "你好")
        XCTAssertEqual(m.transcript.interimText, "世界")
    }

    @MainActor
    func testInterimOnlyCountsAsTranscript() {
        let m = FloatingHUDModel()
        m.updateTranscript(PartialTranscript(finalText: "", interimText: "嗯"))
        XCTAssertTrue(m.hasTranscript)
    }

    @MainActor
    func testSetFinalTranscriptClearsInterim() {
        let m = FloatingHUDModel()
        m.updateTranscript(PartialTranscript(finalText: "你好", interimText: "世界"))
        m.setFinalTranscript("你好世界。")
        XCTAssertEqual(m.transcript.finalText, "你好世界。")
        XCTAssertEqual(m.transcript.interimText, "")
    }

    @MainActor
    func testResetTranscriptClearsEverything() {
        let m = FloatingHUDModel()
        m.updateTranscript(PartialTranscript(finalText: "x", interimText: "y"))
        m.resetTranscript()
        XCTAssertFalse(m.hasTranscript)
        XCTAssertEqual(m.transcript, .empty)
    }
}
