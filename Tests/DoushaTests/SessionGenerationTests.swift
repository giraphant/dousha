import XCTest
import TalkerCommonSync

final class SessionGenerationTests: XCTestCase {
    func testFreshGenerationMatchesLive() {
        var g = SessionGeneration()
        XCTAssertTrue(g.isCurrent(g.live))
    }

    func testBumpInvalidatesPriorToken() {
        var g = SessionGeneration()
        let first = g.live
        let second = g.bump()
        XCTAssertFalse(g.isCurrent(first), "old token must no longer be current after bump")
        XCTAssertTrue(g.isCurrent(second), "the bumped token is current")
    }

    func testTokensFromDifferentGenerationsDiffer() {
        var g = SessionGeneration()
        let a = g.bump()
        let b = g.bump()
        XCTAssertNotEqual(a, b)
    }
}
