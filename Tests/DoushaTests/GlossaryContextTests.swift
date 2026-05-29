import XCTest
@testable import Dousha

final class GlossaryContextTests: XCTestCase {
    func testEmptyInput_returnsEmptyString() {
        XCTAssertEqual(GlossaryContext.encode([]), "")
    }

    func testAllWhitespaceOrEmpty_returnsEmptyString() {
        XCTAssertEqual(GlossaryContext.encode(["", "   ", "\n\t"]), "")
    }

    func testJoinsTermsWithEnumerationComma() {
        XCTAssertEqual(GlossaryContext.encode(["甲", "乙", "丙"]), "甲、乙、丙")
    }

    func testTrimsEachTerm() {
        XCTAssertEqual(GlossaryContext.encode(["  甲 ", "\t乙\n"]), "甲、乙")
    }

    func testDropsEmptyTermsButKeepsOrder() {
        XCTAssertEqual(GlossaryContext.encode(["甲", "  ", "乙"]), "甲、乙")
    }

    func testDeduplicatesPreservingFirstSeenOrder() {
        XCTAssertEqual(GlossaryContext.encode(["甲", "乙", "甲", "丙", "乙"]), "甲、乙、丙")
    }

    func testDedupAppliesAfterTrimming() {
        // "甲" and " 甲 " collapse to the same trimmed term.
        XCTAssertEqual(GlossaryContext.encode(["甲", " 甲 "]), "甲")
    }

    func testCapsAtMaxTermCount() {
        let terms = (0..<(GlossaryContext.maxTerms + 10)).map { "t\($0)" }
        let result = GlossaryContext.encode(terms)
        let count = result.components(separatedBy: GlossaryContext.separator).count
        XCTAssertEqual(count, GlossaryContext.maxTerms)
    }

    func testCapsAtMaxCharCount() {
        // Each term is 20 chars; with the separator, far fewer than maxTerms fit
        // before the 500-char ceiling.
        let long = String(repeating: "x", count: 20)
        let terms = Array(repeating: "", count: 0) + (0..<60).map { "\(long)\($0)" }
        let result = GlossaryContext.encode(terms)
        XCTAssertLessThanOrEqual(result.count, GlossaryContext.maxChars)
        // And it must have included at least a few terms, not bailed early.
        XCTAssertFalse(result.isEmpty)
    }

    func testSingleTerm_noSeparator() {
        XCTAssertEqual(GlossaryContext.encode(["甲"]), "甲")
    }

    func testSingleTermLongerThanMaxChars_isDroppedNotTruncated() {
        // Design: skip rather than truncate. A first term that alone exceeds the
        // char ceiling is dropped entirely, yielding "".
        let overlong = String(repeating: "x", count: GlossaryContext.maxChars + 1)
        XCTAssertEqual(GlossaryContext.encode([overlong]), "")
    }

    func testOverlongFirstTermDropped_laterFittingTermStillIncluded() {
        let overlong = String(repeating: "x", count: GlossaryContext.maxChars + 1)
        XCTAssertEqual(GlossaryContext.encode([overlong, "甲"]), "甲")
    }

    // MARK: - normalize (used by Soniox context.terms)

    func testNormalize_trimsDropsEmptyAndDedups() {
        XCTAssertEqual(
            GlossaryContext.normalize(["  甲 ", "乙", "", "甲", " 乙 ", "丙"]),
            ["甲", "乙", "丙"]
        )
    }

    func testNormalize_emptyInput() {
        XCTAssertEqual(GlossaryContext.normalize([]), [])
        XCTAssertEqual(GlossaryContext.normalize(["", "  "]), [])
    }

    func testNormalize_capsAtMaxTerms() {
        let terms = (0..<(GlossaryContext.maxTerms + 10)).map { "t\($0)" }
        XCTAssertEqual(GlossaryContext.normalize(terms).count, GlossaryContext.maxTerms)
    }

    func testNormalize_doesNotApplyCharCap() {
        // Unlike encode (Doubao string), normalize keeps an overlong term — Soniox
        // accepts a large terms array, so we don't drop on char length here.
        let overlong = String(repeating: "x", count: GlossaryContext.maxChars + 1)
        XCTAssertEqual(GlossaryContext.normalize([overlong]), [overlong])
    }
}
