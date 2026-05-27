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
