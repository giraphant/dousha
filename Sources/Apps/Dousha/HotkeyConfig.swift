import Foundation

enum HotkeyMode: String, Codable, CaseIterable {
    case pushToTalk
    case toggle
}

struct HotkeyConfig: Codable, Equatable {
    let keyCode: UInt16
    let mode: HotkeyMode

    static let `default` = HotkeyConfig(keyCode: 60, mode: .pushToTalk) // Right Shift, PTT
}

/// Single-press hotkey that cancels an in-flight recording. Separate from
/// `HotkeyConfig` because the recording hotkey is modifier-only (whitelist-checked
/// against `HotkeyMonitor.modifierMask`) while cancel can be any key, including
/// disabled. `keyCode == nil` means the cancel hotkey is turned off entirely.
struct CancelHotkeyConfig: Codable, Equatable {
    /// nil disables the cancel hotkey.
    let keyCode: UInt16?

    /// macOS virtual keycode for Esc — the default.
    static let escKeyCode: UInt16 = 53

    static let `default` = CancelHotkeyConfig(keyCode: escKeyCode)
    static let disabled = CancelHotkeyConfig(keyCode: nil)

    var isEnabled: Bool { keyCode != nil }

    var displayName: String {
        guard let kc = keyCode else { return "Off" }
        return CancelHotkeyConfig.displayName(forKeyCode: kc)
    }

    /// Best-effort human-readable label for a virtual keycode. Covers the keys
    /// users are most likely to bind to cancel; falls back to "Key N" for
    /// anything else.
    static func displayName(forKeyCode keyCode: UInt16) -> String {
        switch keyCode {
        case 53:  return "Esc"
        case 49:  return "Space"
        case 36:  return "Return"
        case 76:  return "Enter"
        case 48:  return "Tab"
        case 51:  return "Delete"
        case 117: return "Forward Delete"
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 123: return "Left"
        case 124: return "Right"
        case 125: return "Down"
        case 126: return "Up"
        default:  return "Key \(keyCode)"
        }
    }
}
