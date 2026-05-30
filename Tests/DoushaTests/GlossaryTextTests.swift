import XCTest
@testable import Dousha

final class GlossaryTextTests: XCTestCase {

    func test_splitsOnIdeographicCommaCommasSemicolonsAndNewlines() {
        let text = "布迪厄、哈贝马斯，福柯,韦伯；涂尔干\n齐美尔"
        XCTAssertEqual(
            GlossaryText.parse(text),
            ["布迪厄", "哈贝马斯", "福柯", "韦伯", "涂尔干", "齐美尔"]
        )
    }

    func test_trimsWhitespaceAroundEachTerm() {
        XCTAssertEqual(GlossaryText.parse("  福柯 、 韦伯  "), ["福柯", "韦伯"])
    }

    func test_dropsEmptyPiecesFromRepeatedOrTrailingSeparators() {
        XCTAssertEqual(GlossaryText.parse("福柯、、韦伯，\n"), ["福柯", "韦伯"])
    }

    func test_deduplicatesPreservingFirstSeenOrder() {
        XCTAssertEqual(GlossaryText.parse("福柯、韦伯、福柯"), ["福柯", "韦伯"])
    }

    func test_doesNotSplitOnSpacesSoMultiWordTermsSurvive() {
        XCTAssertEqual(
            GlossaryText.parse("machine learning、deep learning"),
            ["machine learning", "deep learning"]
        )
    }

    func test_emptyOrSeparatorOnlyTextYieldsNoTerms() {
        XCTAssertEqual(GlossaryText.parse(""), [])
        XCTAssertEqual(GlossaryText.parse("、，\n  "), [])
    }

    func test_formatJoinsWithIdeographicComma() {
        XCTAssertEqual(GlossaryText.format(["福柯", "韦伯"]), "福柯、韦伯")
        XCTAssertEqual(GlossaryText.format([]), "")
    }
}
