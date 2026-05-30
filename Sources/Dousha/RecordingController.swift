import Foundation
import ASRSupport
import TalkerCommonSync

/// The side-effect surface a `RecordingController` needs. Built once by
/// `AppDelegate` (same struct-of-closures pattern as `SettingsActions`); faked
/// in tests. Every closure runs on the main actor.
@MainActor
struct RecordingEnvironment {
    /// Build a fresh backend from current preferences (called at each start()).
    var makeBackend: () -> SpeechBackend
    /// Apply the new status to the HUD (glow/content). Does NOT control visibility.
    var applyStatusToHUD: (RecordingStatus) -> Void
    /// Show (true) / hide (false) the floating HUD window.
    var setHUDVisible: (Bool) -> Void
    /// Reset the hotkey dispatcher to "no session active".
    var forceDispatcherIdle: () -> Void
    /// Clear the HUD audio-level history (start of a recording).
    var resetHUDLevels: () -> Void
    /// Clear the HUD transcript (start of a recording, and on error).
    var resetHUDTranscript: () -> Void
    /// Live partial during recording.
    var updateHUDTranscript: (PartialTranscript) -> Void
    /// Audio level during recording.
    var pushHUDLevel: (Float) -> Void
    /// Final transcript shown just before inject.
    var setFinalTranscript: (String) -> Void
    /// Paste text into the focused field.
    var inject: (String) -> Void
    /// Replace the clipboard contents (deferred-refine rewrite).
    var writeClipboard: (String) -> Void
    /// Whether LLM refinement is enabled AND configured.
    var isRefineEnabled: () -> Bool
    /// Immediate vs deferred refine policy.
    var refineMode: () -> RefineMode
    /// Refine `text` and call back with the refined string, or nil to keep raw.
    var refineImmediate: (_ text: String, _ done: @escaping (String?) -> Void) -> Void
    /// Kick off a deferred refine that writes the refined text to the clipboard later.
    var refineLater: (_ text: String) -> Void
    /// Current dictation language identifier.
    var language: () -> String
    /// Wall-clock now (injectable for the teardown-guard / timing tests).
    var now: () -> Date
    /// Run `work` after `delay` on the main actor (injectable for tests).
    var scheduleAfter: (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void
}

/// Owns one dictation session's state machine + lifecycle + timing defenses.
/// Extracted from AppDelegate (QUA-163 Phase 1). All state is main-actor-isolated
/// except `recordingFlag`, a Lock the cancel-key event-tap thread reads directly.
@MainActor
final class RecordingController {
    // Timing constants — single source of truth (were scattered asyncAfter literals).
    static let cancelTeardownGuard: TimeInterval = 0.25
    static let injectGreenFlash: TimeInterval = 0.25
    static let errorAutoReset: TimeInterval = 3.0

    private let env: RecordingEnvironment
    private var backend: SpeechBackend?

    private(set) var status: RecordingStatus = .idle

    /// Recording-state mirror read from the cancel-key CGEvent-tap thread. The
    /// controller OWNS it and sets it as the first line of every transition, so
    /// the "flag before HUD" ordering that AppDelegate's didSet enforced by hand
    /// is now guaranteed by construction. Handed to CancelKeyMonitor by AppDelegate.
    let recordingFlag = Lock<Bool>(false)

    /// Monotonic staleness counter (was AppDelegate.sessionToken). Bumped ONLY on
    /// cancel; stop/error capture it but never bump it.
    private var generation: UInt64 = 0

    /// Earliest time the next start() may call into the backend after a cancel.
    private var nextStartAllowedAt: Date?

    init(environment: RecordingEnvironment) {
        self.env = environment
    }

    // MARK: - State machine

    /// The single place status changes. Applies the ordered side effects that
    /// used to live in AppDelegate's `status.didSet`.
    private func transition(to next: RecordingStatus) {
        let old = status
        // 1. Mirror FIRST (cancel-key tap reads this; must never be stale).
        recordingFlag.setValue(next == .recording)
        // 2. Commit + drive HUD glow/content.
        status = next
        env.applyStatusToHUD(next)
        // 3. Returning to idle resets the hotkey dispatcher.
        if next == .idle && old != .idle {
            env.forceDispatcherIdle()
        }
        // 4. Show/hide only on a visibility transition (no strobe on interior steps).
        if old.isVisible != next.isVisible {
            env.setHUDVisible(next.isVisible)
        }
    }

    // Test-only seam to exercise `transition` directly.
    #if DEBUG
    func testHook_transition(to next: RecordingStatus) { transition(to: next) }
    #endif

    private func isErrorStatus(_ s: RecordingStatus) -> Bool {
        if case .error = s { return true }
        return false
    }
}
