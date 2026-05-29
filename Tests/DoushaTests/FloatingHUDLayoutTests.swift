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
    func testMaxHeightIsFiveTranscriptLinesAboveCompact() {
        XCTAssertEqual(FloatingHUDView.maxTranscriptLines, 5)
        XCTAssertEqual(
            FloatingHUDView.maxHeight,
            FloatingHUDView.compactHeight
                + FloatingHUDView.transcriptLineHeight * CGFloat(FloatingHUDView.maxTranscriptLines)
        )
    }
}
