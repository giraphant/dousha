import XCTest
@testable import Dousha

final class LanguageRouterTests: XCTestCase {
    // doubao = Chinese specialist, soniox = English/mixed.
    private let router = LanguageRouter(chineseEngine: .doubao,
                                        englishEngine: .soniox,
                                        mixedEngine: .soniox)

    // MARK: - composition ratios

    func testComposition_pureChinese() {
        let (cjk, latin) = LanguageRouter.composition("你好世界")
        XCTAssertEqual(cjk, 1.0, accuracy: 0.001)
        XCTAssertEqual(latin, 0.0, accuracy: 0.001)
    }

    func testComposition_pureEnglish() {
        let (cjk, latin) = LanguageRouter.composition("hello world")
        XCTAssertEqual(cjk, 0.0, accuracy: 0.001)
        XCTAssertEqual(latin, 1.0, accuracy: 0.001)
    }

    func testComposition_ignoresPunctuationAndDigits() {
        // "你好, 123!" → only 你好 are classifiable → 100% CJK.
        let (cjk, _) = LanguageRouter.composition("你好, 123!")
        XCTAssertEqual(cjk, 1.0, accuracy: 0.001)
    }

    func testComposition_mixed() {
        // 用(cjk) Python(6 latin) 写(cjk) API(3 latin) → cjk=2, latin=9, total=11
        let (cjk, latin) = LanguageRouter.composition("用 Python 写 API")
        XCTAssertEqual(cjk, 2.0 / 11.0, accuracy: 0.001)
        XCTAssertEqual(latin, 9.0 / 11.0, accuracy: 0.001)
    }

    // MARK: - slot routing

    func testSlot_chineseDominant_goesToChineseEngine() {
        // 20 Han + 1 Latin → 20/21 ≈ 0.95 → Chinese
        XCTAssertEqual(router.slot(forScoreText: "今天天气很好我们一起去公园散步聊天喝茶x"), .doubao)
    }

    func testSlot_englishDominant_goesToEnglishEngine() {
        XCTAssertEqual(router.slot(forScoreText: "please run the build now"), .soniox)
    }

    func testSlot_mixed_goesToMixedEngine() {
        // 用 Python 写 API: cjk 2/11 (<0.95), latin 9/11 (>0.5) → English slot here,
        // so craft a genuinely balanced one: 我用它写 code → cjk 4/8=0.5 each
        XCTAssertEqual(router.slot(forScoreText: "我现在用它写 code"), .soniox) // latin? 我现在用它写=6 cjk, code=4 latin → cjk .6 latin .4 → not >0.5 latin, not >=.95 cjk → mixed
    }

    func testSlot_emptyText_goesToMixed() {
        XCTAssertEqual(router.slot(forScoreText: "   123 !!!  "), router.mixedEngine)
    }

    // MARK: - pickBest

    func testPickBest_routesByPrimaryThenReturnsSlotResult() {
        // Chinese-dominant text from both; should pick Chinese engine (doubao).
        let results: [Engine: String] = [.doubao: "你好世界你好", .soniox: "你好world你好"]
        let pick = router.pickBest(results: results, primary: .doubao)
        XCTAssertEqual(pick?.engine, .doubao)
        XCTAssertEqual(pick?.text, "你好世界你好")
    }

    func testPickBest_englishRoutesToSoniox() {
        let results: [Engine: String] = [.doubao: "皮森 哈喽", .soniox: "Python hello"]
        // score on primary (doubao) text "皮森 哈喽" = pure CJK → would pick doubao...
        // so make primary the English speaker; here primary=soniox.
        let pick = router.pickBest(results: results, primary: .soniox)
        XCTAssertEqual(pick?.engine, .soniox)
        XCTAssertEqual(pick?.text, "Python hello")
    }

    func testPickBest_primaryEmpty_scoresFallbackAndPicks() {
        // primary (doubao) empty → score soniox's english text → english slot = soniox
        let results: [Engine: String] = [.doubao: "", .soniox: "hello there friend"]
        let pick = router.pickBest(results: results, primary: .doubao)
        XCTAssertEqual(pick?.engine, .soniox)
        XCTAssertEqual(pick?.text, "hello there friend")
    }

    func testPickBest_chosenSlotEmpty_fallsThroughToNonEmpty() {
        // Chinese-dominant score → chosen = doubao, but doubao empty → fall through to soniox.
        let results: [Engine: String] = [.doubao: "", .soniox: "你好世界你好"]
        let pick = router.pickBest(results: results, primary: .soniox)
        XCTAssertEqual(pick?.engine, .soniox)
        XCTAssertEqual(pick?.text, "你好世界你好")
    }

    func testPickBest_allEmpty_returnsNil() {
        let results: [Engine: String] = [.doubao: "", .soniox: ""]
        XCTAssertNil(router.pickBest(results: results, primary: .doubao))
    }

    func testPickBest_singleEngineDegenerate() {
        let solo = LanguageRouter(chineseEngine: .apple, englishEngine: .apple, mixedEngine: .apple)
        let results: [Engine: String] = [.apple: "anything goes here"]
        let pick = solo.pickBest(results: results, primary: .apple)
        XCTAssertEqual(pick?.engine, .apple)
        XCTAssertEqual(pick?.text, "anything goes here")
    }
}
