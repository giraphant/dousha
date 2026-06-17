import CoreGraphics
import XCTest
@testable import Dousha

@MainActor
final class HUDScreenResolverTests: XCTestCase {
    func testAccessibilityFrameFlipsFromTopLeftIntoAppKitCoordinates() {
        let frame = HUDScreenResolver.appKitWindowFrameFromAccessibility(
            position: CGPoint(x: 120, y: 30),
            size: CGSize(width: 500, height: 240),
            primaryScreenMaxY: 900
        )

        XCTAssertEqual(frame, CGRect(x: 120, y: 630, width: 500, height: 240))
    }

    func testBestScreenFrameUsesLargestWindowIntersection() {
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = CGRect(x: -200, y: 100, width: 500, height: 300)

        XCTAssertEqual(
            HUDScreenResolver.bestScreenFrame(forWindowFrame: window, screenFrames: [left, main]),
            main
        )
    }

    func testBestScreenFrameReturnsNilForOffscreenWindow() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let offscreen = CGRect(x: 3000, y: 100, width: 400, height: 300)

        XCTAssertNil(HUDScreenResolver.bestScreenFrame(forWindowFrame: offscreen, screenFrames: [main]))
    }

    func testInvalidAccessibilityFrameIsIgnored() {
        XCTAssertNil(
            HUDScreenResolver.appKitWindowFrameFromAccessibility(
                position: CGPoint(x: 10, y: 10),
                size: CGSize(width: 0, height: 200),
                primaryScreenMaxY: 900
            )
        )
    }
}
