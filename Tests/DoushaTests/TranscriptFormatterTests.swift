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

    // MARK: - Rule: widen half-width punctuation in Han context (QUA-194)

    func test_widensHalfWidthPunctuationAfterHan() {
        XCTAssertEqual(TranscriptFormatter.widenCJKPunctuation("你好,世界"), "你好，世界")
        XCTAssertEqual(TranscriptFormatter.widenCJKPunctuation("真的吗?"), "真的吗？")
        XCTAssertEqual(TranscriptFormatter.widenCJKPunctuation("好的."), "好的。")
        XCTAssertEqual(TranscriptFormatter.widenCJKPunctuation("注意:这里!"), "注意：这里！")
        XCTAssertEqual(TranscriptFormatter.widenCJKPunctuation("第一;第二"), "第一；第二")
    }

    func test_widensPunctuationBeforeHanAfterLatinWord() {
        // The mark trails a Latin term but the sentence is Chinese.
        XCTAssertEqual(TranscriptFormatter.widenCJKPunctuation("用Cursor,然后写代码"), "用Cursor，然后写代码")
        XCTAssertEqual(TranscriptFormatter.widenCJKPunctuation("版本是v2.我觉得可以"), "版本是v2。我觉得可以")
    }

    func test_widenLeavesPureEnglishAlone() {
        XCTAssertEqual(TranscriptFormatter.widenCJKPunctuation("Hello, world. Really? Yes!"),
                       "Hello, world. Really? Yes!")
        XCTAssertEqual(TranscriptFormatter.widenCJKPunctuation("see: item; done"), "see: item; done")
    }

    func test_widenLeavesDigitContextAlone() {
        XCTAssertEqual(TranscriptFormatter.widenCJKPunctuation("增长了3.5倍"), "增长了3.5倍")
        XCTAssertEqual(TranscriptFormatter.widenCJKPunctuation("写了5,000字"), "写了5,000字")
        XCTAssertEqual(TranscriptFormatter.widenCJKPunctuation("时间是2:30吧"), "时间是2:30吧")
    }

    func test_widenKeepsDotBeforeAsciiIdentifier() {
        // `.` directly followed by ASCII alnum stays a dot even after Han.
        XCTAssertEqual(TranscriptFormatter.widenCJKPunctuation("我说.NET很好"), "我说.NET很好")
        XCTAssertEqual(TranscriptFormatter.widenCJKPunctuation("去github.com看看"), "去github.com看看")
    }

    func test_widenIsIdempotent() {
        let once = TranscriptFormatter.widenCJKPunctuation("你好,世界.")
        XCTAssertEqual(TranscriptFormatter.widenCJKPunctuation(once), once)
    }

    func test_normalizeWidensThenStripsTrailingSpace() {
        // Half-width comma + space after Han: widen first, then the tighten
        // pass sees a full-width mark and strips the space.
        XCTAssertEqual(TranscriptFormatter.normalize("你好, 世界"), "你好，世界")
        XCTAssertEqual(TranscriptFormatter.normalize("可以的. 然后呢?"), "可以的。然后呢？")
    }

    // MARK: - Pipeline: normalize = widen + tighten + pangu

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
