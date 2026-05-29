import XCTest
@testable import Dousha

final class FloatingHUDLayoutTests: XCTestCase {
    @MainActor
    func testRecordingActionsOverlayDoesNotIncreaseHUDHeight() {
        XCTAssertEqual(FloatingHUDView.cardMaxHeight, 71)
        XCTAssertEqual(FloatingHUDView.cardMaxHeight, FloatingHUDView.compactHeight)
    }

    @MainActor
    func testCompactContentUsesQuarterAxes() {
        XCTAssertEqual(FloatingHUDView.contextRowCenterYRatio, 0.30)
        XCTAssertEqual(FloatingHUDView.levelMeterCenterYRatio, 0.70)
    }
}
