import XCTest
import ASRSupport

/// QUA-263: deterministic tests for the streaming text reconciler. Pure text
/// in, operation out — no ASR server, no Accessibility, no target apps.
final class StreamingTextReconcilerTests: XCTestCase {
    private func reconcile(_ previous: String, _ candidate: String)
        -> StreamingTextReconciler.Operation {
        StreamingTextReconciler.reconcile(previous: previous, candidate: candidate)
    }

    // MARK: Exact match

    func testIdenticalSnapshotsAreNoChange() {
        let op = reconcile("今天天气很好", "今天天气很好")
        XCTAssertEqual(op.kind, .noChange)
        XCTAssertEqual(op.stablePrefixCount, 6)
        XCTAssertEqual(op.deleteGraphemeCount, 0)
        XCTAssertEqual(op.insertion, "")
    }

    func testBothEmptyIsNoChange() {
        let op = reconcile("", "")
        XCTAssertEqual(op.kind, .noChange)
        XCTAssertEqual(op.stablePrefixCount, 0)
        XCTAssertEqual(op.deleteGraphemeCount, 0)
    }

    // MARK: Append-only

    func testGrowingHypothesisIsAppendOnly() {
        let op = reconcile("hello wor", "hello world")
        XCTAssertEqual(op.kind, .appendOnly)
        XCTAssertEqual(op.stablePrefixCount, 9)
        XCTAssertEqual(op.deleteGraphemeCount, 0)
        XCTAssertEqual(op.insertion, "ld")
    }

    func testGrowingChineseHypothesisIsAppendOnly() {
        let op = reconcile("我们去", "我们去公园")
        XCTAssertEqual(op.kind, .appendOnly)
        XCTAssertEqual(op.stablePrefixCount, 3)
        XCTAssertEqual(op.insertion, "公园")
    }

    func testFirstSnapshotOntoEmptyIsAppendOnly() {
        let op = reconcile("", "你好")
        XCTAssertEqual(op.kind, .appendOnly)
        XCTAssertEqual(op.stablePrefixCount, 0)
        XCTAssertEqual(op.deleteGraphemeCount, 0)
        XCTAssertEqual(op.insertion, "你好")
    }

    // MARK: Replace-tail

    func testTailRevisionIsReplaceTail() {
        let op = reconcile("今天天气很好", "今天天气真好")
        XCTAssertEqual(op.kind, .replaceTail)
        XCTAssertEqual(op.stablePrefixCount, 4)
        XCTAssertEqual(op.deleteGraphemeCount, 2)
        XCTAssertEqual(op.insertion, "真好")
    }

    func testCompleteRewriteReplacesEverything() {
        let op = reconcile("speech", "特殊")
        XCTAssertEqual(op.kind, .replaceTail)
        XCTAssertEqual(op.stablePrefixCount, 0)
        XCTAssertEqual(op.deleteGraphemeCount, 6)
        XCTAssertEqual(op.insertion, "特殊")
    }

    func testShrinkingToAPrefixIsPureTruncation() {
        let op = reconcile("hello world", "hello")
        XCTAssertEqual(op.kind, .replaceTail)
        XCTAssertEqual(op.stablePrefixCount, 5)
        XCTAssertEqual(op.deleteGraphemeCount, 6)
        XCTAssertEqual(op.insertion, "")
    }

    // MARK: Punctuation is preserved, never normalized (QUA-263)

    func testChinesePunctuationChangeIsARealEdit() {
        let op = reconcile("你好，世界", "你好。世界")
        XCTAssertEqual(op.kind, .replaceTail)
        XCTAssertEqual(op.stablePrefixCount, 2)
        XCTAssertEqual(op.deleteGraphemeCount, 3)
        XCTAssertEqual(op.insertion, "。世界")
    }

    func testFullWidthVsHalfWidthCommaIsARealEdit() {
        let op = reconcile("你好,世界", "你好，世界")
        XCTAssertEqual(op.kind, .replaceTail)
        XCTAssertEqual(op.stablePrefixCount, 2)
        XCTAssertEqual(op.deleteGraphemeCount, 3)
        XCTAssertEqual(op.insertion, "，世界")
    }

    func testAppendedTerminalPunctuationIsAppendOnly() {
        let op = reconcile("今天天气很好", "今天天气很好。")
        XCTAssertEqual(op.kind, .appendOnly)
        XCTAssertEqual(op.insertion, "。")
    }

    // MARK: Whitespace-only changes are real edits

    func testInsertedSpaceIsARealEdit() {
        let op = reconcile("hello world", "hello  world")
        XCTAssertEqual(op.kind, .replaceTail)
        XCTAssertEqual(op.stablePrefixCount, 6)
        XCTAssertEqual(op.deleteGraphemeCount, 5)
        XCTAssertEqual(op.insertion, " world")
    }

    func testTrailingSpaceIsAppendOnly() {
        let op = reconcile("hello", "hello ")
        XCTAssertEqual(op.kind, .appendOnly)
        XCTAssertEqual(op.insertion, " ")
    }

    // MARK: Empty candidate is held (never erases visible text)

    func testEmptyCandidateHoldsVisibleText() {
        let op = reconcile("已经上屏的文字", "")
        XCTAssertEqual(op.kind, .noChange)
        XCTAssertEqual(op.stablePrefixCount, 7)
        XCTAssertEqual(op.deleteGraphemeCount, 0)
        XCTAssertEqual(op.insertion, "")
        XCTAssertEqual(op.apply(to: "已经上屏的文字"), "已经上屏的文字")
    }

    // MARK: Grapheme-cluster safety

    func testCountsAreGraphemeClusters() {
        // Family emoji: 1 Character, 7 unicode scalars.
        let op = reconcile("看👨‍👩‍👧", "看👨‍👩‍👧了")
        XCTAssertEqual(op.kind, .appendOnly)
        XCTAssertEqual(op.stablePrefixCount, 2)
        XCTAssertEqual(op.insertion, "了")
    }

    func testEmojiRevisionNeverSplitsACluster() {
        let op = reconcile("看👨‍👩‍👧", "看👨‍👩‍👦")
        XCTAssertEqual(op.kind, .replaceTail)
        XCTAssertEqual(op.stablePrefixCount, 1)
        XCTAssertEqual(op.deleteGraphemeCount, 1)
        XCTAssertEqual(op.insertion, "👨‍👩‍👦")
    }

    func testCanonicallyEquivalentButDifferentScalarsIsARealEdit() {
        let precomposed = "caf\u{00E9}"      // é as one scalar
        let decomposed = "cafe\u{0301}"      // e + combining acute
        XCTAssertEqual(precomposed, decomposed) // equal per Swift, but…
        let op = reconcile(precomposed, decomposed)
        // …scalar-exact matching still replaces, so apply() reproduces the
        // candidate's exact bytes.
        XCTAssertEqual(op.kind, .replaceTail)
        XCTAssertEqual(op.stablePrefixCount, 3)
        XCTAssertEqual(op.deleteGraphemeCount, 1)
        XCTAssertEqual(op.insertion, "e\u{0301}")
        XCTAssertTrue(op.apply(to: precomposed).unicodeScalars
            .elementsEqual(decomposed.unicodeScalars))
    }

    func testRegionalIndicatorFlagIsReplacedWhole() {
        // 🇨🇳 and 🇨🇦 share their first regional-indicator scalar but are
        // single clusters — the flag is replaced whole, never half-matched.
        let op = reconcile("去🇨🇳", "去🇨🇦")
        XCTAssertEqual(op.kind, .replaceTail)
        XCTAssertEqual(op.stablePrefixCount, 1)
        XCTAssertEqual(op.deleteGraphemeCount, 1)
        XCTAssertEqual(op.insertion, "🇨🇦")
    }

    func testCRLFIsOneCluster() {
        let op = reconcile("line\r", "line\r\n")
        // \r\n is a single grapheme cluster, so extending \r to \r\n is a
        // one-cluster replacement, not an append.
        XCTAssertEqual(op.kind, .replaceTail)
        XCTAssertEqual(op.stablePrefixCount, 4)
        XCTAssertEqual(op.deleteGraphemeCount, 1)
        XCTAssertEqual(op.insertion, "\r\n")
    }

    // MARK: apply(to:) round-trip invariant

    func testApplyReproducesCandidateExactly() {
        let cases: [(String, String)] = [
            ("", ""),
            ("", "第一句"),
            ("hello wor", "hello world"),
            ("今天天气很好", "今天天气真好"),
            ("你好，世界", "你好。世界"),
            ("hello world", "hello"),
            ("speech", "特殊"),
            ("看👨‍👩‍👧", "看👨‍👩‍👦"),
            ("a b", "a  b"),
        ]
        for (previous, candidate) in cases {
            let op = reconcile(previous, candidate)
            XCTAssertTrue(op.apply(to: previous).unicodeScalars
                .elementsEqual(candidate.unicodeScalars),
                "apply() must reproduce '\(candidate)' from '\(previous)'")
            XCTAssertEqual(op.deleteGraphemeCount, previous.count - op.stablePrefixCount)
        }
    }
}
