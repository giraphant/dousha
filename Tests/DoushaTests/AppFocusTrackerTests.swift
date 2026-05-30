import XCTest
import AppKit
@testable import Dousha

// @MainActor: AppFocusTracker is @MainActor; these tests drive it synchronously.
@MainActor
final class AppFocusTrackerTests: XCTestCase {
    func testIgnore_returnsTrueForSelfBundleId() {
        let tracker = AppFocusTracker(selfBundleId: "com.dousha.app")
        XCTAssertTrue(tracker.shouldIgnore(bundleId: "com.dousha.app"))
    }

    func testIgnore_returnsFalseForOtherBundleId() {
        let tracker = AppFocusTracker(selfBundleId: "com.dousha.app")
        XCTAssertFalse(tracker.shouldIgnore(bundleId: "com.apple.Safari"))
        XCTAssertFalse(tracker.shouldIgnore(bundleId: nil))
    }

    func testApplyActivation_updatesCurrentForOtherApp() {
        let tracker = AppFocusTracker(selfBundleId: "com.dousha.app")
        let img = NSImage(size: NSSize(width: 1, height: 1))
        tracker.applyActivation(bundleId: "com.apple.Safari", name: "Safari", icon: img)
        XCTAssertEqual(tracker.current?.name, "Safari")
    }

    func testApplyActivation_doesNotUpdateForSelf() {
        let tracker = AppFocusTracker(selfBundleId: "com.dousha.app")
        let safariIcon = NSImage(size: NSSize(width: 1, height: 1))
        tracker.applyActivation(bundleId: "com.apple.Safari", name: "Safari", icon: safariIcon)
        // Now Dousha becomes frontmost (user opened Settings).
        let doushaIcon = NSImage(size: NSSize(width: 1, height: 1))
        tracker.applyActivation(bundleId: "com.dousha.app", name: "Dousha", icon: doushaIcon)
        // Tracker should still report Safari as the meaningful focus target.
        XCTAssertEqual(tracker.current?.name, "Safari")
    }
}
