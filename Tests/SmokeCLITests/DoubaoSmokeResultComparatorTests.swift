import XCTest
@testable import SmokeCLISupport

final class DoubaoSmokeResultComparatorTests: XCTestCase {
    func testCompareExactMatchAgainstOfficial() {
        let entries = [
            DoubaoSmokeResultComparator.SummaryEntry(fixture: "overlap", profile: "official", transcript: "明天开会。", diagnostics: "(none observed)"),
            DoubaoSmokeResultComparator.SummaryEntry(fixture: "overlap", profile: "asr-split", transcript: "明天开会。", diagnostics: "(none observed)")
        ]

        let rows = DoubaoSmokeResultComparator.compare(entries: entries)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].fixture, "overlap")
        XCTAssertEqual(rows[0].profile, "asr-split")
        XCTAssertTrue(rows[0].exactMatch)
        XCTAssertTrue(rows[0].normalizedMatch)
        XCTAssertFalse(rows[0].candidateEmpty)
        XCTAssertEqual(rows[0].lengthDelta, 0)
        XCTAssertEqual(rows[0].similarity, 1.0)
    }

    func testCompareNormalizesWhitespaceButPreservesPunctuation() {
        let official = DoubaoSmokeResultComparator.SummaryEntry(fixture: "tail", profile: "official", transcript: "明天 开会。", diagnostics: "")
        let candidate = DoubaoSmokeResultComparator.SummaryEntry(fixture: "tail", profile: "speaker-nested", transcript: " 明天\n开会。 ", diagnostics: "")

        let row = DoubaoSmokeResultComparator.compare(official: official, candidate: candidate)

        XCTAssertFalse(row.exactMatch)
        XCTAssertTrue(row.normalizedMatch)
        XCTAssertGreaterThan(row.similarity, 0.5)
    }

    func testCompareDetectsPunctuationDifference() {
        let official = DoubaoSmokeResultComparator.SummaryEntry(fixture: "tail", profile: "official", transcript: "明天开会。", diagnostics: "")
        let candidate = DoubaoSmokeResultComparator.SummaryEntry(fixture: "tail", profile: "speaker-nested", transcript: "明天开会", diagnostics: "")

        let row = DoubaoSmokeResultComparator.compare(official: official, candidate: candidate)

        XCTAssertFalse(row.exactMatch)
        XCTAssertFalse(row.normalizedMatch)
        XCTAssertEqual(row.lengthDelta, -1)
        XCTAssertEqual(row.commonPrefixLength, 4)
    }

    func testCompareSkipsCandidatesWithoutOfficialBaseline() {
        let entries = [
            DoubaoSmokeResultComparator.SummaryEntry(fixture: "missing", profile: "asr-split", transcript: "文本", diagnostics: "")
        ]

        XCTAssertTrue(DoubaoSmokeResultComparator.compare(entries: entries).isEmpty)
    }

    func testSummaryPathAcceptsJsonFileOrDirectory() {
        XCTAssertEqual(DoubaoSmokeResultComparator.summaryPath(for: "/tmp/result.json"), "/tmp/result.json")
    }
}
