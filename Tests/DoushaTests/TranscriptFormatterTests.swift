import XCTest
import ASRSupport
@testable import SonioxASR

final class TranscriptFormatterTests: XCTestCase {
    // MARK: - Rule: strip stray spaces on the Chinese side

    func test_stripsSpaceAfterFullWidthPunctuation() {
        XCTAssertEqual(TranscriptFormatter.tightenCJKSpaces("你好。 世界"), "你好。世界")
        XCTAssertEqual(TranscriptFormatter.tightenCJKSpaces("然后这样， 再然后这样。"), "然后这样，再然后这样。")
    }

    func test_stripsSpaceBeforeFullWidthPunctuation() {
        XCTAssertEqual(TranscriptFormatter.tightenCJKSpaces("你好 。"), "你好。")
        XCTAssertEqual(TranscriptFormatter.tightenCJKSpaces("括号 （ 内容 ）"), "括号（内容）")
    }

    func test_stripsSpaceBetweenTwoHanCharacters() {
        // Mid-sentence pause: Soniox wedges a space between two Han ideographs.
        XCTAssertEqual(TranscriptFormatter.tightenCJKSpaces("我觉得 这个很好"), "我觉得这个很好")
        XCTAssertEqual(TranscriptFormatter.tightenCJKSpaces("英伟达 发布 新款"), "英伟达发布新款")
    }

    func test_preservesSpaceBetweenChineseAndLatinOrDigits() {
        XCTAssertEqual(TranscriptFormatter.tightenCJKSpaces("Dousha 是一个 App"), "Dousha 是一个 App")
        XCTAssertEqual(TranscriptFormatter.tightenCJKSpaces("第 3 章"), "第 3 章")
    }

    func test_preservesNormalEnglishSpacingAndAsciiPunctuation() {
        XCTAssertEqual(TranscriptFormatter.tightenCJKSpaces("Hello, world. Bye."), "Hello, world. Bye.")
    }

    func test_idempotentAndNoSpaceFastPath() {
        XCTAssertEqual(TranscriptFormatter.tightenCJKSpaces("你好世界"), "你好世界")
        let once = TranscriptFormatter.tightenCJKSpaces("你好， 世界")
        XCTAssertEqual(TranscriptFormatter.tightenCJKSpaces(once), once)
    }

    // MARK: - Rule: 盘古之白 (pangu)

    func test_panguInsertsSpaceBetweenCJKAndLatin() {
        XCTAssertEqual(TranscriptFormatter.pangu("strip掉看一看"), "strip 掉看一看")
        XCTAssertEqual(TranscriptFormatter.pangu("测出来strip的问题"), "测出来 strip 的问题")
        XCTAssertEqual(TranscriptFormatter.pangu("第3章"), "第 3 章")
        XCTAssertEqual(TranscriptFormatter.pangu("用Cursor写代码"), "用 Cursor 写代码")
    }

    func test_panguIsIdempotentAndKeepsExistingSpaces() {
        XCTAssertEqual(TranscriptFormatter.pangu("用 Cursor 写代码"), "用 Cursor 写代码")
        let once = TranscriptFormatter.pangu("strip掉")
        XCTAssertEqual(TranscriptFormatter.pangu(once), once)
    }

    func test_panguNeverSpacesBeforeFullWidthPunctuation() {
        // The Latin side is followed by a full-width comma/period — no space.
        XCTAssertEqual(TranscriptFormatter.pangu("一个bug，没问题"), "一个 bug，没问题")
        XCTAssertEqual(TranscriptFormatter.pangu("写了5000，"), "写了 5000，")
    }

    func test_panguLeavesPureLatinAndPureCJKAlone() {
        XCTAssertEqual(TranscriptFormatter.pangu("Hello world 2024"), "Hello world 2024")
        XCTAssertEqual(TranscriptFormatter.pangu("你好世界"), "你好世界")
    }

    // MARK: - Pipeline: normalize = tighten + pangu

    func test_normalizeStripsBadSpacesAndAddsMissingOnes() {
        // The real reproduced Soniox case: stray space after 。 plus glued strip掉.
        XCTAssertEqual(
            TranscriptFormatter.normalize("可以strip掉看一看。 对。 我没测出来strip的问题"),
            "可以 strip 掉看一看。对。我没测出来 strip 的问题"
        )
    }

    func test_normalizeIsIdempotent() {
        let once = TranscriptFormatter.normalize("用Cursor写代码。 第3章")
        XCTAssertEqual(TranscriptFormatter.normalize(once), once)
    }

    // MARK: - Integration through the Soniox parser path

    func test_normalizeViaSonioxDisplayTextAcrossTokenBoundary() {
        var parser = SonioxResponseParser()
        parser.ingest(jsonData: Data(#"{"tokens":[{"text":"用Cursor写代码。","is_final":true}]}"#.utf8))
        parser.ingest(jsonData: Data(#"{"tokens":[{"text":" 第3章","is_final":true}]}"#.utf8))
        XCTAssertEqual(parser.displayText, "用 Cursor 写代码。第 3 章")
    }

    func test_normalizeViaSonioxAsyncParser() {
        let parser = SonioxAsyncTranscriptParser()
        let obj: [String: Any] = ["tokens": [["text": "你好。"], ["text": " 世界"]]]
        XCTAssertEqual(parser.parse(object: obj), "你好。世界")
    }
}
