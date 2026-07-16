import XCTest
import ASRSupport

/// QUA-264 local correction layer. Every test is deterministic — the corrector
/// is a pure function of (config, input). The rule *order* asserted here
/// (user replacements → term casing → spacing → trailing punctuation) is part
/// of the public contract; see the `TranscriptCorrector` doc comment.
final class TranscriptCorrectorTests: XCTestCase {

    private func corrector(rules: [String] = [],
                           terms: [String] = TranscriptCorrector.builtinCasingTerms)
        -> TranscriptCorrector {
        TranscriptCorrector(replacements: rules.compactMap(TranscriptCorrector.Replacement.parse),
                            casingTerms: terms)
    }

    // MARK: - Bypass / trivial input

    func testDisabledIsIdentity() {
        var c = corrector(rules: ["阿派=>API"])
        c.isEnabled = false
        XCTAssertEqual(c.correct("阿派挂了。。"), "阿派挂了。。")
    }

    func testEmptyAndUntouchedTextPassThrough() {
        let c = corrector()
        XCTAssertEqual(c.correct(""), "")
        XCTAssertEqual(c.correct("今天天气不错。"), "今天天气不错。")
        XCTAssertEqual(c.correct("Plain English stays plain."), "Plain English stays plain.")
    }

    // MARK: - Rule 1: user replacements

    func testReplacementAppliesToAllOccurrences() {
        let c = corrector(rules: ["个特=>Git"])
        XCTAssertEqual(c.correct("用个特提交，个特很快"), "用 Git 提交，Git 很快")
    }

    func testReplacementIsCaseSensitive() {
        let c = corrector(rules: ["jason=>JSON"], terms: [])
        XCTAssertEqual(c.correct("jason or Jason"), "JSON or Jason")
    }

    func testLatinReplacementRespectsWordBoundaries() {
        let c = corrector(rules: ["cat=>Kat"], terms: [])
        XCTAssertEqual(c.correct("cat in category"), "Kat in category")
    }

    func testEmptyReplacementDeletesPhrase() {
        let c = corrector(rules: ["嗯=>"], terms: [])
        XCTAssertEqual(c.correct("嗯这样嗯就好"), "这样就好")
    }

    func testReplacementsApplyInListOrder() {
        // First rule's output is visible to the second.
        let c = corrector(rules: ["阿派=>API", "API 挂=>API 崩"], terms: [])
        XCTAssertEqual(c.correct("阿派 挂了"), "API 崩了")
    }

    func testReplacementRunsBeforeCasing() {
        // The replacement may produce lowercase; rule 2 then re-cases it.
        let c = corrector(rules: ["吉特哈布=>github"])
        XCTAssertEqual(c.correct("上吉特哈布看看"), "上 GitHub 看看")
    }

    func testParseRuleFormat() {
        XCTAssertEqual(TranscriptCorrector.Replacement.parse("阿派=>API"),
                       TranscriptCorrector.Replacement(match: "阿派", replacement: "API"))
        // First `=>` splits; the rest belongs to the replacement.
        XCTAssertEqual(TranscriptCorrector.Replacement.parse("a=>b=>c")?.replacement, "b=>c")
        XCTAssertNil(TranscriptCorrector.Replacement.parse("no separator"))
        XCTAssertNil(TranscriptCorrector.Replacement.parse("=>right"))
        XCTAssertNil(TranscriptCorrector.Replacement.parse("  =>right"))
    }

    // MARK: - Rule 2: term casing

    func testCasingFixesKnownTerms() {
        let c = corrector()
        XCTAssertEqual(c.correct("open claude code and check the json"),
                       "open Claude Code and check the JSON")
    }

    func testCasingRespectsWordBoundaries() {
        let c = corrector()
        // "api" inside "rapid" / "ui" inside "quit" must survive.
        XCTAssertEqual(c.correct("rapid quit"), "rapid quit")
        // Extended-Latin neighbours join words too: no casing inside "éapi".
        XCTAssertEqual(c.correct("éapi"), "éapi")
    }

    func testCommonEnglishWordsAreNotInBuiltins() {
        // "python" (the snake), "docker" (a dock worker), "app store" (generic)
        // must survive by default — conservative-default acceptance criterion.
        let c = corrector()
        XCTAssertEqual(c.correct("a python escaped the app store"),
                       "a python escaped the app store")
    }

    func testCasingAcrossCJKSeamAddsPanguSpace() {
        let c = corrector()
        XCTAssertEqual(c.correct("用api解析json数据"), "用 API 解析 JSON 数据")
    }

    func testMultiWordTermBeatsItsPrefix() {
        // "Claude Code" (longer) must win over "Claude" even though both match.
        let c = corrector()
        XCTAssertEqual(c.correct("claude code 和 claude"), "Claude Code 和 Claude")
    }

    func testEarlierTermWinsOnCaseInsensitiveDuplicate() {
        // Caller puts user terms first, so a user's casing overrides a built-in.
        let c = corrector(terms: ["MacOS"] + TranscriptCorrector.builtinCasingTerms)
        XCTAssertEqual(c.correct("升级 macos"), "升级 MacOS")
    }

    func testGlossaryStyleTermEnforcesCasing() {
        let c = corrector(terms: ["Quasifish"] + TranscriptCorrector.builtinCasingTerms)
        XCTAssertEqual(c.correct("quasifish 的 QUASIFISH"), "Quasifish 的 Quasifish")
    }

    func testCaselessTermsAreIgnored() {
        // Pure-CJK glossary terms carry no casing signal; they must be inert.
        let c = corrector(terms: ["豆包", "  ", ""])
        XCTAssertEqual(c.correct("豆包很好用"), "豆包很好用")
    }

    func testSentenceStartCapitalizedVariantIsRecased() {
        let c = corrector()
        XCTAssertEqual(c.correct("Json is fine"), "JSON is fine")
    }

    // MARK: - Rule 4: trailing punctuation

    func testDoubledTerminalMarkCollapses() {
        let c = corrector()
        XCTAssertEqual(c.correct("好的。。"), "好的。")
        XCTAssertEqual(c.correct("really!!"), "really!")
    }

    func testTripleMarkReadsAsEllipsisAndSurvives() {
        let c = corrector()
        XCTAssertEqual(c.correct("I think..."), "I think...")
        XCTAssertEqual(c.correct("好的。。。"), "好的。。。")
    }

    func testMixedPunctuationTailIsLeftAlone() {
        // TranscriptFormatter widens a Han-adjacent "." (pre-existing QUA-194
        // behavior), so "我想想..." reaches the tail rule as "我想想。..".
        // A pair preceded by a different terminal mark must not collapse —
        // rewriting a mixed tail risks making it worse.
        let c = corrector()
        XCTAssertEqual(c.correct("我想想..."), "我想想。..")
        XCTAssertEqual(c.correct("真的吗？。"), "真的吗？。")
    }

    func testDanglingClauseSeparatorsDrop() {
        let c = corrector()
        XCTAssertEqual(c.correct("然后，"), "然后")
        XCTAssertEqual(c.correct("第一、"), "第一")
        XCTAssertEqual(c.correct("接着。。，"), "接着。")
    }

    func testDeliberateTrailingPunctuationSurvives() {
        let c = corrector()
        // English trailing comma can be a dictated salutation — full-width
        // Chinese marks only. Colons are legitimate endings in both widths.
        XCTAssertEqual(c.correct("Dear Alice,"), "Dear Alice,")
        XCTAssertEqual(c.correct("清单如下："), "清单如下：")
    }

    func testInteriorPunctuationIsNeverTouched() {
        let c = corrector()
        XCTAssertEqual(c.correct("先这样，然后那样。再说！"), "先这样，然后那样。再说！")
    }

    // MARK: - Pipeline properties

    func testCorrectIsIdempotent() {
        // Idempotency holds for the built-in rules and for user rules whose
        // output doesn't re-contain their match (`foo=>foo bar` would compound;
        // the production run-once contract is what covers that case — see the
        // TranscriptCorrector doc comment).
        let c = corrector(rules: ["阿派=>API", "嗯=>"])
        let samples = [
            "嗯用阿派解析json数据。。",
            "open claude code,",
            "先这样，然后那样。再说！",
            "我想想...",
        ]
        for s in samples {
            let once = c.correct(s)
            XCTAssertEqual(c.correct(once), once, "not idempotent for: \(s)")
        }
    }

    func testWhitespaceLeftByDeletionIsTrimmed() {
        let c = corrector(rules: ["um=>"], terms: [])
        XCTAssertEqual(c.correct("um so yeah um"), "so yeah")
        // An interior deletion must not leave a double space behind.
        XCTAssertEqual(c.correct("so um yeah"), "so yeah")
    }
}
