import XCTest
@testable import Dousha

final class LanguageMenuTests: XCTestCase {
    func test_doubaoMenuShowsOnlyAutoRegardlessOfSavedLanguage() {
        let options = LanguageMenu.options(for: .doubao, selectedLanguage: Language.en_US.rawValue)

        XCTAssertEqual(options, [
            LanguageMenu.Option(title: "Auto", rawValue: LanguageMenu.autoIdentifier, isSelected: true)
        ])
    }

    func test_appleMenuShowsConcreteLanguagesAndKeepsSavedSelection() {
        let options = LanguageMenu.options(for: .apple, selectedLanguage: Language.en_US.rawValue)

        XCTAssertEqual(options.map(\.rawValue), Language.allCases.map(\.rawValue))
        XCTAssertEqual(options.filter(\.isSelected).map(\.rawValue), [Language.en_US.rawValue])
        XCTAssertFalse(options.map(\.rawValue).contains(LanguageMenu.autoIdentifier))
    }

    func test_doubaoDetectorLanguageDoesNotUseSavedAppleLanguage() {
        XCTAssertEqual(
            LanguageMenu.detectorLanguage(for: .doubao, selectedLanguage: Language.en_US.rawValue),
            LanguageMenu.autoIdentifier
        )
    }
}
