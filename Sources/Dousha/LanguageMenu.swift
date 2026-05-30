import Foundation

struct LanguageMenu {
    static let autoIdentifier = "auto"

    struct Option: Equatable {
        let title: String
        let rawValue: String
        let isSelected: Bool
    }

    /// Language options for the menu bar.
    ///
    /// - Single engine: behaviour follows the engine. Apple needs an explicit
    ///   locale (lists all); Doubao/Soniox auto-detect (just 「自动」).
    /// - Multi-engine: there is no 「自动」 — a primary language must be forced so
    ///   one routing slot is the primary/HUD engine. The only meaningful primary
    ///   languages are 中文 / 英文 (混合 ≡ 自动, never a primary). 中文 → zh-CN,
    ///   英文 → en-US; anything not en-* selects 中文.
    static func options(activeEngines: [Engine],
                        primaryEngine: Engine,
                        selectedLanguage: String) -> [Option] {
        let isMultiEngine = Set(activeEngines).count > 1
        if isMultiEngine {
            let isEnglish = selectedLanguage.hasPrefix("en")
            return [
                Option(title: "中文", rawValue: Language.zh_CN.rawValue, isSelected: !isEnglish),
                Option(title: "英文", rawValue: Language.en_US.rawValue, isSelected: isEnglish)
            ]
        }

        switch primaryEngine {
        case .apple:
            return Language.allCases.map { lang in
                Option(
                    title: lang.displayName,
                    rawValue: lang.rawValue,
                    isSelected: lang.rawValue == selectedLanguage
                )
            }
        case .doubao, .soniox:
            return [Option(title: "自动", rawValue: autoIdentifier, isSelected: true)]
        }
    }
}
