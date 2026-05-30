import Foundation

struct LanguageMenu {
    static let autoIdentifier = "auto"

    struct Option: Equatable {
        let title: String
        let rawValue: String
        let isSelected: Bool
    }

    static func options(for engine: Engine, selectedLanguage: String) -> [Option] {
        switch engine {
        case .apple:
            return Language.allCases.map { lang in
                Option(
                    title: lang.displayName,
                    rawValue: lang.rawValue,
                    isSelected: lang.rawValue == selectedLanguage
                )
            }
        case .doubao, .soniox, .fusion:
            return [Option(title: "自动", rawValue: autoIdentifier, isSelected: true)]
        }
    }

    static func detectorLanguage(for engine: Engine, selectedLanguage: String) -> String {
        switch engine {
        case .apple:
            return selectedLanguage
        case .doubao, .soniox, .fusion:
            return autoIdentifier
        }
    }
}
