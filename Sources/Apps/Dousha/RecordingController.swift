import Foundation
import ASRSupport
import ConcurrencySupport

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
    /// Enable cancel-key event delivery only while cancellation is valid.
    var setCancelKeyEnabled: (Bool) -> Void
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
    /// Builds the local deterministic correction pass (QUA-264) applied to the
    /// final transcript before it reaches the HUD / refiner / injector. Called
    /// once per start() so the correction config is snapshotted when recording
    /// begins — the same rule the engines follow for the glossary; a Settings
    /// change mid-recording must not mutate a live session's result.
    var makeCorrector: () -> (String) -> String
    /// Paste text into the focused field.
    var inject: (String) -> Void
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

    /// The task draining the backend's event stream for the live session.
    /// Cancelling it (plus `backend.cancel()` finishing the stream) is the
    /// structural replacement for the old manual `generation` staleness guard:
    /// once cancelled, no further event can re-enter.
    private var sessionTask: Task<Void, Never>?

    /// Earliest time the next start() may call into the backend after a cancel.
    private var nextStartAllowedAt: Date?

    /// The correction pass snapshotted by the current session's start()
    /// (QUA-264). Identity until the first start so a stray final can't crash.
    private var sessionCorrect: (String) -> String = { $0 }

    init(environment: RecordingEnvironment) {
        self.env = environment
    }

    // MARK: - State machine

    /// The single place status changes. Applies the ordered side effects that
    /// used to live in AppDelegate's `status.didSet`.
    private func transition(to next: RecordingStatus) {
        let old = status
        // 1. Mirror FIRST (cancel-key tap reads this; must never be stale).
        let isRecording = next == .recording
        recordingFlag.setValue(isRecording)
        env.setCancelKeyEnabled(isRecording)
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
        if next == .idle { backend = nil }
    }

    // MARK: - Lifecycle

    func start() {
        guard status == .idle || isErrorStatus(status) else {
            doushaLog("[RecordingController] start REJECTED (status=\(status))")
            return
        }
        // Defer if a recent cancel hasn't finished tearing down (backend cancel is
        // async; starting into a still-draining session would silently no-op).
        let now = env.now()
        if let allowedAt = nextStartAllowedAt, allowedAt > now {
            let delay = allowedAt.timeIntervalSince(now)
            doushaLog("[RecordingController] start deferred \(Int(delay * 1000))ms for cancel teardown")
            env.scheduleAfter(delay) { [weak self] in self?.start() }
            return
        }
        nextStartAllowedAt = nil

        let backend = env.makeBackend()
        self.backend = backend
        sessionCorrect = env.makeCorrector()   // config snapshot at start (QUA-264)
        transition(to: .recording)
        backend.setLanguage(env.language())
        env.resetHUDLevels()
        env.resetHUDTranscript()

        let stream = backend.start()
        sessionTask?.cancel()        // defensive: no overlapping consumer
        sessionTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .partial(let partial):
                    // Drop late partials once we've left .recording so a batch
                    // emitted just before stop() can't clobber the final.
                    guard self.status == .recording else { continue }
                    self.env.updateHUDTranscript(partial)
                case .audioLevel(let level):
                    self.env.pushHUDLevel(level)
                case .error(let message):
                    doushaLog("[RecordingController] recognition error: \(message)")
                    // Intentionally NOT cancelling the consumer loop here: the stop()
                    // issued inside transitionToError produces a trailing .final
                    // (dropped by handleFinal's guard) and then finishes the stream,
                    // so the task exits on its own — parallel to the explicit
                    // sessionTask?.cancel() on the cancel() path.
                    self.transitionToError(message)
                case .final(let result):
                    self.handleFinal(result)
                }
            }
        }
    }

    private func transitionToError(_ message: String) {
        // Idempotent: a flood of cascading server errors must not keep re-deferring
        // the idle reset.
        if case .error = status { return }
        transition(to: .error(message))
        env.resetHUDTranscript()
        // Release mic / socket so the next start() isn't stacked on a live session.
        backend?.stop()
        env.scheduleAfter(Self.errorAutoReset) { [weak self] in
            guard let self = self, self.isErrorStatus(self.status) else { return }
            self.transition(to: .idle)
        }
    }

    func cancel() {
        guard status == .recording else {
            doushaLog("[RecordingController] cancel REJECTED (status=\(status))")
            return
        }
        backend?.cancel()            // finishes the stream → consumer loop ends
        sessionTask?.cancel()
        sessionTask = nil
        nextStartAllowedAt = env.now().addingTimeInterval(Self.cancelTeardownGuard)
        transition(to: .idle)
    }

    func stop() {
        guard status == .recording else {
            doushaLog("[RecordingController] stop REJECTED (status=\(status))")
            return
        }
        transition(to: .transcribing)
        backend?.stop()
    }

    /// Handles the terminal `.final` event. Replaces the old `stop(completion:)`
    /// closure body. The `status == .transcribing` guard replaces the old
    /// `generation == myGen` check: a `.final` arriving after an error/idle
    /// (e.g. from the `stop()` we issue inside `transitionToError`) is dropped.
    private func handleFinal(_ result: TranscriptionResult) {
        guard status == .transcribing else {
            doushaLog("[RecordingController] final dropped (status=\(status))")
            return
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { transition(to: .idle); return }
        // QUA-264: local correction runs before the HUD final so what the user
        // sees is what gets injected. A correction that empties the text (e.g.
        // a filler-word deletion rule ate everything) ends the session quietly.
        let corrected = sessionCorrect(text)
        guard !corrected.isEmpty else { transition(to: .idle); return }
        env.setFinalTranscript(corrected)
        refineAndInject(corrected)
    }

    private func refineAndInject(_ text: String) {
        guard env.isRefineEnabled() else { injectAndFinish(text); return }
        switch env.refineMode() {
        case .immediate:
            env.refineImmediate(text) { [weak self] refined in
                self?.injectAndFinish(refined ?? text)
            }
        case .deferred:
            injectAndFinish(text)
            env.refineLater(text)
        }
    }

    private func injectAndFinish(_ text: String) {
        transition(to: .injecting)
        env.inject(text)
        env.scheduleAfter(Self.injectGreenFlash) { [weak self] in
            self?.transition(to: .idle)
        }
    }

    // Test-only seam to exercise `transition` directly.
    #if DEBUG
    func testHook_transition(to next: RecordingStatus) { transition(to: next) }
    var testHook_hasBackend: Bool { backend != nil }
    #endif

    private func isErrorStatus(_ s: RecordingStatus) -> Bool {
        if case .error = s { return true }
        return false
    }
}
