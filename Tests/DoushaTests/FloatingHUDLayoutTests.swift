import XCTest
@testable import Dousha

final class FloatingHUDLayoutTests: XCTestCase {
    @MainActor
    func testCompactCardHeightUnchanged() {
        // The empty/no-text card keeps its original design + height.
        XCTAssertEqual(FloatingHUDView.compactHeight, 71)
        XCTAssertEqual(FloatingHUDView.cardHeight, 71)
    }

    @MainActor
    func testCompactContentUsesQuarterAxes() {
        // Compact (empty) layout positions are preserved.
        XCTAssertEqual(FloatingHUDView.contextRowCenterYRatio, 0.30)
        XCTAssertEqual(FloatingHUDView.levelMeterCenterYRatio, 0.70)
    }

    @MainActor
    func testCardCanGrowFromCompactToCap() {
        // Once transcript text arrives the card grows beyond compact.
        XCTAssertGreaterThan(FloatingHUDView.maxHeight, FloatingHUDView.compactHeight)
        // The fixed panel is sized to the grown cap so the card always fits.
        XCTAssertEqual(FloatingHUDView.cardMaxHeight, FloatingHUDView.maxHeight)
    }

    @MainActor
    func testTranscriptAreaCapsAtFiveVisibleLines() {
        XCTAssertEqual(FloatingHUDView.maxTranscriptLines, 5)
        XCTAssertEqual(
            FloatingHUDView.transcriptMaxHeight,
            FloatingHUDView.transcriptTopPadding
                + FloatingHUDView.transcriptLineHeight * CGFloat(FloatingHUDView.maxTranscriptLines)
        )
        XCTAssertEqual(
            FloatingHUDView.maxHeight,
            FloatingHUDView.transcriptMaxHeight + FloatingHUDView.meterRegionHeight
        )
    }
}
