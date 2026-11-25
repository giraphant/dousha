import XCTest
@testable import MLXASR

final class MLXGlossaryEchoGuardTests: XCTestCase {
    private let sampleContext = """
    Vocabulary:
    - quasi
    - 吉登斯
    - 非人
    - 能动性
    """

    func testExtractTerms_parsesVocabularyBulletListAndPlainLists() {
        XCTAssertEqual(
            MLXGlossaryEchoGuard.extractTerms(from: sampleContext),
            ["quasi", "吉登斯", "非人", "能动性"]
        )
        XCTAssertEqual(
            MLXGlossaryEchoGuard.extractTerms(from: "吉登斯、福柯，quasi; 能动性"),
            ["吉登斯", "福柯", "quasi", "能动性"]
        )
        XCTAssertEqual(MLXGlossaryEchoGuard.extractTerms(from: "   \n "), [])
    }

    func testHasSubstantiveText_treatsPunctuationAndWhitespaceAsEmpty() {
        XCTAssertFalse(MLXGlossaryEchoGuard.hasSubstantiveText(""))
        XCTAssertFalse(MLXGlossaryEchoGuard.hasSubstantiveText("   \n  "))
        XCTAssertFalse(MLXGlossaryEchoGuard.hasSubstantiveText("。"))
        XCTAssertFalse(MLXGlossaryEchoGuard.hasSubstantiveText("...，！？"))
        XCTAssertTrue(MLXGlossaryEchoGuard.hasSubstantiveText("好"))
        XCTAssertTrue(MLXGlossaryEchoGuard.hasSubstantiveText("OK。"))
    }

    func testClassify_detectsExactTranslatedVocabularyPromptLeakage() {
        // Exact real-world failure reported after 10s of ambient room noise.
        XCTAssertEqual(
            MLXGlossaryEchoGuard.classify(
                batchText: "词汇：quasi，吉登斯，非人，能动性。",
                context: sampleContext
            ),
            .promptLeakage
        )
        XCTAssertEqual(
            MLXGlossaryEchoGuard.classify(
                batchText: "Vocabulary: quasi, 吉登斯, 非人, 能动性",
                context: sampleContext
            ),
            .promptLeakage
        )
        XCTAssertEqual(
            MLXGlossaryEchoGuard.classify(
                batchText: "- quasi\n- 吉登斯\n- 非人\n- 能动性",
                context: sampleContext
            ),
            .promptLeakage
        )
        XCTAssertEqual(
            MLXGlossaryEchoGuard.classify(
                batchText: "词汇表：吉登斯、非人",
                context: sampleContext
            ),
            .promptLeakage
        )
        XCTAssertEqual(
            MLXGlossaryEchoGuard.classify(
                batchText: "词汇 quasi，吉登斯，非人，能动性。",
                context: sampleContext
            ),
            .promptLeakage
        )
        XCTAssertEqual(
            MLXGlossaryEchoGuard.classify(
                batchText: "关键词：quasi，吉登斯，非人，能动。",
                context: sampleContext
            ),
            .promptLeakage
        )
    }

    func testClassify_detectsGlossaryOnlyDumpAndLoneGlossaryTerm() {
        XCTAssertEqual(
            MLXGlossaryEchoGuard.classify(batchText: "吉登斯", context: sampleContext),
            .glossaryOnly(matchedTermCount: 1)
        )
        XCTAssertEqual(
            MLXGlossaryEchoGuard.classify(batchText: "吉登斯。", context: sampleContext),
            .glossaryOnly(matchedTermCount: 1)
        )
        XCTAssertEqual(
            MLXGlossaryEchoGuard.classify(batchText: "quasi，吉登斯，非人，能动性。", context: sampleContext),
            .glossaryOnly(matchedTermCount: 4)
        )
        XCTAssertEqual(
            MLXGlossaryEchoGuard.classify(batchText: "嗯，quasi，吉登斯，非人，能动性。", context: sampleContext),
            .glossaryOnly(matchedTermCount: 4)
        )
    }

    func testClassify_leavesNormalDictationsAlone() {
        XCTAssertEqual(
            MLXGlossaryEchoGuard.classify(
                batchText: "我觉得吉登斯的非人能动性理论很有启发。",
                context: sampleContext
            ),
            .normal
        )
        XCTAssertEqual(
            MLXGlossaryEchoGuard.classify(
                batchText: "今天下午去图书馆写论文。",
                context: sampleContext
            ),
            .normal
        )
        XCTAssertEqual(
            MLXGlossaryEchoGuard.classify(
                batchText: "词汇：quasi，吉登斯，非人，能动性。",
                context: ""
            ),
            .normal
        )
    }

    func testNeedsUnbiasedVerification_catchesUncorroboratedGlossaryExpansionOverNoisyStream() {
        // Streaming heard only 1 noise char "嗯" on 10s ambient noise, while
        // biased batch expanded into a longer sentence containing glossary terms.
        let check = MLXGlossaryEchoGuard.needsUnbiasedVerification(
            batchText: "嗯，这是吉登斯的非人能动性。",
            streamFallback: "嗯",
            context: sampleContext
        )
        XCTAssertTrue(check.verify)

        // Normal speech: streaming already heard a full sentence → no verification needed.
        let normal = MLXGlossaryEchoGuard.needsUnbiasedVerification(
            batchText: "我觉得吉登斯的非人能动性理论很有启发。",
            streamFallback: "我觉得基登斯的非人能动性理论很有启发",
            context: sampleContext
        )
        XCTAssertFalse(normal.verify)
    }

    func testResolve_suppressesHallucinationsAndPreservesCorroboratedSpeech() {
        // 1. Prompt leakage + empty unbiased → suppressed.
        let leaked = MLXGlossaryEchoGuard.resolve(
            biasedBatch: "词汇：quasi，吉登斯，非人，能动性。",
            unbiasedBatch: "",
            streamFallback: "嗯",
            classification: .promptLeakage
        )
        XCTAssertEqual(leaked.text, "")
        XCTAssertTrue(leaked.suppressedHallucination)

        // 2. Glossary dump + 1-char noise unbiased ("嗯") → suppressed.
        let noisyUnbiased = MLXGlossaryEchoGuard.resolve(
            biasedBatch: "quasi，吉登斯，非人，能动性。",
            unbiasedBatch: "嗯",
            streamFallback: "嗯",
            classification: .glossaryOnly(matchedTermCount: 4)
        )
        XCTAssertEqual(noisyUnbiased.text, "")
        XCTAssertTrue(noisyUnbiased.suppressedHallucination)

        // 3. Genuine single-term speech ("吉登斯") corroborated by unbiased ("基登斯") → keep glossary spelling!
        let realTerm = MLXGlossaryEchoGuard.resolve(
            biasedBatch: "吉登斯",
            unbiasedBatch: "基登斯",
            streamFallback: "基登斯",
            classification: .glossaryOnly(matchedTermCount: 1)
        )
        XCTAssertEqual(realTerm.text, "吉登斯")
        XCTAssertFalse(realTerm.suppressedHallucination)

        // 4. Prompt leakage when user somehow really spoke → strip header via unbiased output.
        let realButLeaked = MLXGlossaryEchoGuard.resolve(
            biasedBatch: "词汇：quasi，吉登斯，非人，能动性。",
            unbiasedBatch: "quasi，吉登斯，非人，能动性。",
            streamFallback: "夸赛，基登斯，非人，能动性",
            classification: .promptLeakage
        )
        XCTAssertEqual(realButLeaked.text, "quasi，吉登斯，非人，能动性。")
        XCTAssertFalse(realButLeaked.suppressedHallucination)

        // 5. Verification timeout/failure: prompt leakage always suppressed;
        // uncorroborated single term suppressed; stream-corroborated single term kept.
        XCTAssertTrue(MLXGlossaryEchoGuard.resolve(
            biasedBatch: "词汇：吉登斯",
            unbiasedBatch: nil,
            streamFallback: "词汇吉登斯",
            classification: .promptLeakage
        ).suppressedHallucination)

        XCTAssertTrue(MLXGlossaryEchoGuard.resolve(
            biasedBatch: "吉登斯",
            unbiasedBatch: nil,
            streamFallback: "嗯",
            classification: .glossaryOnly(matchedTermCount: 1)
        ).suppressedHallucination)

        let corroboratedTimeout = MLXGlossaryEchoGuard.resolve(
            biasedBatch: "吉登斯",
            unbiasedBatch: nil,
            streamFallback: "基登斯",
            classification: .glossaryOnly(matchedTermCount: 1)
        )
        XCTAssertEqual(corroboratedTimeout.text, "吉登斯")
        XCTAssertFalse(corroboratedTimeout.suppressedHallucination)
    }
}
