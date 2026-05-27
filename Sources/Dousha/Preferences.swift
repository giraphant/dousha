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
    static let shared = Preferences(defaults: .standard)
    private let defaults: UserDefaults

    private enum Keys {
        static let language              = "language"
        static let engine                = "engine"
        static let llmEnabled            = "llmEnabled"
        static let llmBaseURL            = "llmBaseURL"
        static let llmAPIKey             = "llmAPIKey"
        static let llmModel              = "llmModel"
        static let hotkeyKeyCode         = "hotkey.keyCode"
        static let hotkeyMode            = "hotkey.mode"
        // Sentinel: -1 stored under `cancelHotkey.keyCode` means "disabled".
        // We do not use absence-of-key because UserDefaults.register seeds the
        // default value, which would re-enable Esc whenever a user explicitly
        // turned cancel off and the app restarted.
        static let cancelHotkeyKeyCode   = "cancelHotkey.keyCode"
    }

    /// Stored value used to represent a disabled cancel hotkey. Picked because
    /// it cannot collide with any real macOS virtual keycode (which are non-negative).
    private static let cancelHotkeyDisabledSentinel = -1

    init(defaults: UserDefaults) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.language:             Language.zh_CN.rawValue,
            Keys.engine:               Engine.apple.rawValue,
            Keys.llmEnabled:           false,
            Keys.llmBaseURL:           "https://api.openai.com/v1",
            Keys.llmModel:             "gpt-4o-mini",
            Keys.llmAPIKey:            "",
            Keys.hotkeyKeyCode:        Int(HotkeyConfig.default.keyCode),
            Keys.hotkeyMode:           HotkeyConfig.default.mode.rawValue,
            Keys.cancelHotkeyKeyCode:  Int(CancelHotkeyConfig.escKeyCode)
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

    var hotkey: HotkeyConfig {
        get {
            let code = UInt16(defaults.integer(forKey: Keys.hotkeyKeyCode))
            let mode = HotkeyMode(rawValue: defaults.string(forKey: Keys.hotkeyMode) ?? "")
                ?? HotkeyConfig.default.mode
            return HotkeyConfig(keyCode: code, mode: mode)
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Keys.hotkeyKeyCode)
            defaults.set(newValue.mode.rawValue, forKey: Keys.hotkeyMode)
        }
    }

    var cancelHotkey: CancelHotkeyConfig {
        get {
            // `defaults.integer(forKey:)` collapses "never set + no registered
            // default" into 0, which would be indistinguishable from "user
            // explicitly bound cancel to keycode 0 (= 'a' on US keyboards)".
            // Use `object(forKey:)` to detect actually-set values and fall
            // back to the registered Esc default otherwise.
            guard let raw = defaults.object(forKey: Keys.cancelHotkeyKeyCode) as? Int else {
                return .default
            }
            if raw == Preferences.cancelHotkeyDisabledSentinel {
                return .disabled
            }
            // UInt16 max is 65535 — guard the cast.
            guard raw >= 0, raw <= Int(UInt16.max) else { return .disabled }
            return CancelHotkeyConfig(keyCode: UInt16(raw))
        }
        set {
            if let kc = newValue.keyCode {
                defaults.set(Int(kc), forKey: Keys.cancelHotkeyKeyCode)
            } else {
                defaults.set(Preferences.cancelHotkeyDisabledSentinel,
                             forKey: Keys.cancelHotkeyKeyCode)
            }
        }
    }
}
