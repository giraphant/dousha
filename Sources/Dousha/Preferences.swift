import Foundation

enum Language: String, CaseIterable {
    case en_US = "en-US"
    case zh_CN = "zh-CN"
    case zh_TW = "zh-TW"
    case ja_JP = "ja-JP"
    case ko_KR = "ko-KR"

    var displayName: String {
        switch self {
        case .en_US: return "English"
        case .zh_CN: return "简体中文"
        case .zh_TW: return "繁體中文"
        case .ja_JP: return "日本語"
        case .ko_KR: return "한국어"
        }
    }
}

final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let language     = "language"
        static let engine       = "engine"
        static let llmEnabled   = "llmEnabled"
        static let llmBaseURL   = "llmBaseURL"
        static let llmAPIKey    = "llmAPIKey"
        static let llmModel     = "llmModel"
    }

    private init() {
        defaults.register(defaults: [
            Keys.language:   Language.zh_CN.rawValue,
            Keys.engine:     Engine.apple.rawValue,
            Keys.llmEnabled: false,
            Keys.llmBaseURL: "https://api.openai.com/v1",
            Keys.llmModel:   "gpt-4o-mini",
            Keys.llmAPIKey:  ""
        ])
    }

    var language: String {
        get { defaults.string(forKey: Keys.language) ?? Language.zh_CN.rawValue }
        set { defaults.set(newValue, forKey: Keys.language) }
    }

    var engine: Engine {
        get { Engine(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple }
        set { defaults.set(newValue.rawValue, forKey: Keys.engine) }
    }

    var llmEnabled: Bool {
        get { defaults.bool(forKey: Keys.llmEnabled) }
        set { defaults.set(newValue, forKey: Keys.llmEnabled) }
    }

    var llmBaseURL: String {
        get { defaults.string(forKey: Keys.llmBaseURL) ?? "https://api.openai.com/v1" }
        set { defaults.set(newValue, forKey: Keys.llmBaseURL) }
    }

    var llmAPIKey: String {
        get { defaults.string(forKey: Keys.llmAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.llmAPIKey) }
    }

    var llmModel: String {
        get { defaults.string(forKey: Keys.llmModel) ?? "gpt-4o-mini" }
        set { defaults.set(newValue, forKey: Keys.llmModel) }
    }
}
