import XCTest
import ASRSupport
@testable import Dousha

final class FloatingHUDModelTests: XCTestCase {
    /// Pump the character-reveal to completion (no run loop in tests). Fractional
    /// progress means a single step may not change the visible text, so pump a
    /// fixed, generous number of frames; advanceReveal is a no-op once caught up.
    @MainActor
    private func flushReveal(_ m: FloatingHUDModel, frames: Int = 600) {
        for _ in 0..<frames { m.advanceReveal() }
    }

    @MainActor
    func testStartsEmptyWithNoTranscript() {
        let m = FloatingHUDModel()
        XCTAssertFalse(m.hasTranscript)
        XCTAssertEqual(m.transcript, .empty)
    }

    @MainActor
    func testUpdateTranscriptSwitchesOnImmediatelyAndRevealsTowardTarget() {
        let m = FloatingHUDModel()
        m.updateTranscript(PartialTranscript(finalText: "你好", interimText: "世界"))
        // hasTranscript flips on at once (target-based), so the card switches to
        // transcript mode without waiting for the reveal.
        XCTAssertTrue(m.hasTranscript)
        // The revealed slice is a prefix of the target while catching up.
        XCTAssertTrue("你好世界".hasPrefix(m.transcript.combined))

        flushReveal(m)
        XCTAssertEqual(m.transcript.finalText, "你好")
        XCTAssertEqual(m.transcript.interimText, "世界")
    }

    @MainActor
    func testRevealFillsFinalBeforeInterim() {
        let m = FloatingHUDModel()
        m.updateTranscript(PartialTranscript(finalText: "ab", interimText: "cd"))
        // First revealed characters come from the finalized prefix.
        XCTAssertTrue(m.transcript.interimText.isEmpty || !m.transcript.finalText.isEmpty)
        flushReveal(m)
        XCTAssertEqual(m.transcript.finalText, "ab")
        XCTAssertEqual(m.transcript.interimText, "cd")
    }

    @MainActor
    func testInterimOnlyCountsAsTranscript() {
        let m = FloatingHUDModel()
        m.updateTranscript(PartialTranscript(finalText: "", interimText: "嗯"))
        XCTAssertTrue(m.hasTranscript)
    }

    @MainActor
    func testSetFinalTranscriptShowsFullImmediately() {
        let m = FloatingHUDModel()
        m.updateTranscript(PartialTranscript(finalText: "你好", interimText: "世界"))
        m.setFinalTranscript("你好世界。")
        // No reveal lag on release — full final shown at once, interim cleared.
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

    @MainActor
    func testInterimShrinkSnapsBack() {
        let m = FloatingHUDModel()
        m.updateTranscript(PartialTranscript(finalText: "", interimText: "你好世界朋友"))
        flushReveal(m)
        XCTAssertEqual(m.transcript.combined, "你好世界朋友")
        // Interim replaced by something shorter — revealed must not exceed it.
        m.updateTranscript(PartialTranscript(finalText: "", interimText: "你好"))
        XCTAssertTrue("你好".hasPrefix(m.transcript.combined))
        flushReveal(m)
        XCTAssertEqual(m.transcript.combined, "你好")
    }
}
