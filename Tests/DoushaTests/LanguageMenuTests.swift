import XCTest
@testable import Dousha

final class LanguageMenuTests: XCTestCase {

    // MARK: - 单引擎

    func test_singleDoubaoShowsOnlyAutoRegardlessOfSavedLanguage() {
        let options = LanguageMenu.options(
            activeEngines: [.doubao],
            primaryEngine: .doubao,
            selectedLanguage: Language.en_US.rawValue
        )

        XCTAssertEqual(options, [
            LanguageMenu.Option(title: "自动", rawValue: LanguageMenu.autoIdentifier, isSelected: true)
        ])
    }

    func test_singleSonioxShowsOnlyAutoRegardlessOfSavedLanguage() {
        let options = LanguageMenu.options(
            activeEngines: [.soniox],
            primaryEngine: .soniox,
            selectedLanguage: Language.en_US.rawValue
        )

        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options.first?.rawValue, LanguageMenu.autoIdentifier)
        XCTAssertEqual(options.first?.isSelected, true)
    }

    func test_singleAppleShowsConcreteLanguagesAndKeepsSavedSelection() {
        let options = LanguageMenu.options(
            activeEngines: [.apple],
            primaryEngine: .apple,
            selectedLanguage: Language.en_US.rawValue
        )

        XCTAssertEqual(options.map(\.rawValue), Language.allCases.map(\.rawValue))
        XCTAssertEqual(options.filter(\.isSelected).map(\.rawValue), [Language.en_US.rawValue])
        XCTAssertFalse(options.map(\.rawValue).contains(LanguageMenu.autoIdentifier))
    }

    // MARK: - 多引擎：强制主要语言（中文/英文），不存在「自动」

    func test_multiEngineShowsOnlyChineseAndEnglishNeverAuto() {
        let options = LanguageMenu.options(
            activeEngines: [.doubao, .soniox],
            primaryEngine: .doubao,
            selectedLanguage: Language.zh_CN.rawValue
        )

        XCTAssertEqual(options.map(\.rawValue), [Language.zh_CN.rawValue, Language.en_US.rawValue])
        XCTAssertFalse(options.map(\.rawValue).contains(LanguageMenu.autoIdentifier))
    }

    func test_multiEngineSelectsChineseForChineseLanguage() {
        let options = LanguageMenu.options(
            activeEngines: [.doubao, .soniox],
            primaryEngine: .soniox,
            selectedLanguage: Language.zh_CN.rawValue
        )

        XCTAssertEqual(options.filter(\.isSelected).map(\.rawValue), [Language.zh_CN.rawValue])
    }

    func test_multiEngineSelectsEnglishForEnglishLanguage() {
        let options = LanguageMenu.options(
            activeEngines: [.doubao, .soniox],
            primaryEngine: .doubao,
            selectedLanguage: Language.en_US.rawValue
        )

        XCTAssertEqual(options.filter(\.isSelected).map(\.rawValue), [Language.en_US.rawValue])
    }

    func test_multiEngineDefaultsToChineseForNonEnglishLanguage() {
        // ja-JP / zh-TW / ko-KR 都不是 en-* 前缀，归入「中文」主语言槽。
        let options = LanguageMenu.options(
            activeEngines: [.apple, .soniox],
            primaryEngine: .apple,
            selectedLanguage: Language.ja_JP.rawValue
        )

        XCTAssertEqual(options.filter(\.isSelected).map(\.rawValue), [Language.zh_CN.rawValue])
    }
}
