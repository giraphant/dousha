import Foundation
import SonioxASR

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

enum RefineMode: String, CaseIterable {
    case immediate
    case deferred

    var displayName: String {
        switch self {
        case .immediate: return "立即（等校正后再粘贴）"
        case .deferred:  return "延迟（先粘原文，校正后写入剪贴板）"
        }
    }
}

final class Preferences {
    static let shared = Preferences(defaults: .standard)
    private let defaults: UserDefaults

    private enum Keys {
        static let language                  = "language"
        // Legacy single-engine pref (pre-QUA-145). Still read as the migration
        // seed for the per-language engine slots below, and still written by
        // single-engine quick-switch from the menu bar.
        static let engine                    = "engine"
        // QUA-145 multi-engine: per-language routing slots + the parallel-active set.
        static let chineseEngine             = "chineseEngine"
        static let englishEngine             = "englishEngine"
        static let mixedEngine               = "mixedEngine"
        static let activeEngines             = "activeEngines"
        static let llmEnabled                = "llmEnabled"
        static let llmBaseURL                = "llmBaseURL"
        static let llmAPIKey                 = "llmAPIKey"
        static let llmModel                  = "llmModel"
        static let sonioxAPIKey              = "sonioxAPIKey"
        static let sonioxMode                = "sonioxMode"
        // Engine-agnostic glossary (QUA-133). Key strings keep the historical
        // "doubao" prefix so terms entered before the Soniox extension survive;
        // the feature applies to both Doubao and Soniox.
        static let glossaryEnabled           = "doubaoGlossaryEnabled"
        static let glossaryTerms             = "doubaoGlossaryTerms"
        static let hotkeyKeyCode             = "hotkey.keyCode"
        static let hotkeyMode                = "hotkey.mode"
        // Sentinel: -1 stored under `cancelHotkey.keyCode` means "disabled".
        // We do not use absence-of-key because UserDefaults.register seeds the
        // default value, which would re-enable Esc whenever a user explicitly
        // turned cancel off and the app restarted.
        static let cancelHotkeyKeyCode       = "cancelHotkey.keyCode"
        static let refineMode                = "refineMode"
        static let launchAtLogin             = "launchAtLogin"
        static let showDockIcon              = "showDockIcon"
        static let showMenuBarIcon           = "showMenuBarIcon"
    }

    /// Stored value used to represent a disabled cancel hotkey. Picked because
    /// it cannot collide with any real macOS virtual keycode (which are non-negative).
    private static let cancelHotkeyDisabledSentinel = -1

    init(defaults: UserDefaults) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.language:                 Language.zh_CN.rawValue,
            Keys.engine:                   Engine.apple.rawValue,
            Keys.llmEnabled:               false,
            Keys.llmBaseURL:               "https://api.openai.com/v1",
            Keys.llmModel:                 "gpt-4o-mini",
            Keys.llmAPIKey:                "",
            Keys.sonioxAPIKey:             "",
            Keys.sonioxMode:               SonioxMode.realtime.rawValue,
            Keys.glossaryEnabled:          false,
            Keys.glossaryTerms:            [String](),
            Keys.hotkeyKeyCode:            Int(HotkeyConfig.default.keyCode),
            Keys.hotkeyMode:               HotkeyConfig.default.mode.rawValue,
            Keys.cancelHotkeyKeyCode:      Int(CancelHotkeyConfig.escKeyCode),
            Keys.refineMode:               RefineMode.immediate.rawValue,
            // Menu-bar accessory app by default: no Dock icon, status item shown.
            // `launchAtLogin` here is only a UI mirror; SMAppService is the
            // source of truth and is consulted directly when the window opens.
            Keys.launchAtLogin:            false,
            Keys.showDockIcon:             false,
            Keys.showMenuBarIcon:          true
        ])
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    var showDockIcon: Bool {
        get { defaults.bool(forKey: Keys.showDockIcon) }
        set { defaults.set(newValue, forKey: Keys.showDockIcon) }
    }

    var showMenuBarIcon: Bool {
        get { defaults.bool(forKey: Keys.showMenuBarIcon) }
        set { defaults.set(newValue, forKey: Keys.showMenuBarIcon) }
    }

    var language: String {
        get { defaults.string(forKey: Keys.language) ?? Language.zh_CN.rawValue }
        set { defaults.set(newValue, forKey: Keys.language) }
    }

    /// Legacy single-engine value (pre-QUA-145). Used only as the migration
    /// seed for the routing slots / active set when those haven't been set yet.
    private var legacySingleEngine: Engine {
        Engine(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
    }

    /// The primary engine — the slot matching the current primary language. Drives
    /// HUD partials/level. Computed, not stored: it follows `language`.
    /// Setting it switches to single-engine mode (all slots + active = that engine),
    /// which is what the menu-bar engine quick-switch does.
    var engine: Engine {
        get { primaryEngine(forLanguage: language) }
        set { setSingleEngine(newValue) }
    }

    private func engineSlot(_ key: String) -> Engine {
        Engine(rawValue: defaults.string(forKey: key) ?? "") ?? legacySingleEngine
    }

    /// Engine used when the transcript is ≥95% CJK.
    var chineseEngine: Engine {
        get { engineSlot(Keys.chineseEngine) }
        set { defaults.set(newValue.rawValue, forKey: Keys.chineseEngine) }
    }

    /// Engine used when the transcript is >50% Latin.
    var englishEngine: Engine {
        get { engineSlot(Keys.englishEngine) }
        set { defaults.set(newValue.rawValue, forKey: Keys.englishEngine) }
    }

    /// Engine used for mixed transcripts (between the two thresholds).
    var mixedEngine: Engine {
        get { engineSlot(Keys.mixedEngine) }
        set { defaults.set(newValue.rawValue, forKey: Keys.mixedEngine) }
    }

    /// Engines that run in parallel during a recording. Master set; the three
    /// slots are expected to be chosen from it. Never empty (migrates to the
    /// legacy single engine, then guards against an empty stored array).
    var activeEngines: [Engine] {
        get {
            guard let raw = defaults.stringArray(forKey: Keys.activeEngines) else {
                return [legacySingleEngine]
            }
            let engines = raw.compactMap(Engine.init(rawValue:))
            return engines.isEmpty ? [legacySingleEngine] : engines
        }
        set {
            let unique = newValue.reduce(into: [Engine]()) { acc, e in
                if !acc.contains(e) { acc.append(e) }
            }
            defaults.set((unique.isEmpty ? [legacySingleEngine] : unique).map(\.rawValue),
                         forKey: Keys.activeEngines)
        }
    }

    /// The primary engine for a given primary-language identifier: zh→Chinese
    /// slot, en→English slot, anything else→Mixed slot (catch-all).
    func primaryEngine(forLanguage lang: String) -> Engine {
        if lang.hasPrefix("zh") { return chineseEngine }
        if lang.hasPrefix("en") { return englishEngine }
        return mixedEngine
    }

    /// Collapse to single-engine mode: all three slots and the active set point
    /// at one engine. Zero-overhead degenerate case; what the menu quick-switch uses.
    func setSingleEngine(_ e: Engine) {
        defaults.set(e.rawValue, forKey: Keys.engine)   // keep legacy seed in sync
        chineseEngine = e
        englishEngine = e
        mixedEngine = e
        activeEngines = [e]
    }

    var llmEnabled: Bool {
        get { defaults.bool(forKey: Keys.llmEnabled) }
        set { defaults.set(newValue, forKey: Keys.llmEnabled) }
    }

    var refineMode: RefineMode {
        get { RefineMode(rawValue: defaults.string(forKey: Keys.refineMode) ?? "") ?? .immediate }
        set { defaults.set(newValue.rawValue, forKey: Keys.refineMode) }
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

    var sonioxAPIKey: String {
        get { defaults.string(forKey: Keys.sonioxAPIKey) ?? "" }
        set { defaults.set(newValue, forKey: Keys.sonioxAPIKey) }
    }

    var sonioxMode: SonioxMode {
        get { SonioxMode(rawValue: defaults.string(forKey: Keys.sonioxMode) ?? "") ?? .realtime }
        set { defaults.set(newValue.rawValue, forKey: Keys.sonioxMode) }
    }

    var glossaryEnabled: Bool {
        get { defaults.bool(forKey: Keys.glossaryEnabled) }
        set { defaults.set(newValue, forKey: Keys.glossaryEnabled) }
    }

    var glossaryTerms: [String] {
        get { defaults.stringArray(forKey: Keys.glossaryTerms) ?? [] }
        set { defaults.set(newValue, forKey: Keys.glossaryTerms) }
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
