import XCTest
@testable import Dousha

final class FloatingHUDLayoutTests: XCTestCase {
    @MainActor
    func testCardCanGrowFromCompactToMax() {
        XCTAssertLessThan(FloatingHUDView.compactHeight, FloatingHUDView.maxHeight)
    }

    @MainActor
    func testPanelSizesToMaxHeight() {
        // FloatingWindow derives the (fixed) panel height from cardMaxHeight;
        // it must equal the grown cap so the card never needs a window resize.
        XCTAssertEqual(FloatingHUDView.cardMaxHeight, FloatingHUDView.maxHeight)
    }

    @MainActor
    func testTranscriptAreaCapsAtFiveVisibleLines() {
        XCTAssertEqual(FloatingHUDView.maxTranscriptLines, 5)
        // The transcript text area caps at top padding + 5 line boxes — the real
        // visible-line limit, not just a card growth delta.
        XCTAssertEqual(
            FloatingHUDView.transcriptMaxHeight,
            FloatingHUDView.transcriptTopPadding
                + FloatingHUDView.transcriptLineHeight * CGFloat(FloatingHUDView.maxTranscriptLines)
        )
    }

    @MainActor
    func testCardCapIsTranscriptCapPlusMeterStrip() {
        XCTAssertEqual(
            FloatingHUDView.maxHeight,
            FloatingHUDView.transcriptMaxHeight + FloatingHUDView.meterRegionHeight
        )
    }
}
