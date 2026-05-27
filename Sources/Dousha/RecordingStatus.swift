import SwiftUI

enum RecordingStatus: Equatable {
    case idle
    case recording
    case transcribing
    case injecting
    case error(String)

    /// Whether the floating HUD should be visible at all in this state.
    var isVisible: Bool {
        switch self {
        case .idle: return false
        default:    return true
        }
    }

    /// Outer glow color for the HUD. nil means no glow (used in .idle, where the HUD is hidden anyway).
    var glowColor: Color? {
        switch self {
        case .idle:          return nil
        case .recording:     return Color(red: 1.0, green: 0.42, blue: 0.55) // pink/red
        case .transcribing:  return Color(red: 1.0, green: 0.65, blue: 0.25) // orange
        case .injecting:     return Color(red: 0.30, green: 0.78, blue: 0.45) // green
        case .error:         return Color(red: 0.95, green: 0.80, blue: 0.20) // yellow
        }
    }
}
