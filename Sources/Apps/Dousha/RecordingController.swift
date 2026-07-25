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
    /// Build a replay backend for a saved WAV (re-transcribe; no mic).
    var makeReplayBackend: (URL) -> SpeechBackend
    /// Put re-transcription results on the clipboard (replay never ⌘V-injects).
    var copyToClipboard: (String) -> Void
    /// Archive the just-finished LIVE recording (wav is complete when called).
    /// `error` carries the failure message for a rescued failed dictation.
    /// Returns the new history entry's id, or nil if archiving failed.
    var saveHistory: (_ transcript: String, _ error: String?) -> String?
    /// A successful re-transcription refreshes its history entry's text.
    var updateHistory: (_ id: String, _ transcript: String) -> Void
    /// Re-transcribe a history entry by id — the auto-rescue after a
    /// dead-engines session (issue #46). Routed through the same app path as
    /// the menu's manual 重新转录 (missing-wav handling included).
    var rescue: (_ id: String) -> Void
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

    /// True for a replay (re-transcribe) session: partials show during
    /// .transcribing, the result goes to the clipboard, and history is
    /// updated in place instead of appended.
    private var isReplay = false
    /// History entry the current replay session refreshes on success.
    private var replayHistoryId: String?

    /// Set when a LIVE session's engines all die: the session's terminal .final
    /// (which archives the failed recording to history) has not arrived yet.
    /// While it's set during .recording, capture keeps running to the user's
    /// stop (issue #46 — the mic doesn't need the network). Gates
    /// canRetranscribe so a rescue can't destroy the very recording it wants,
    /// and lets a trailing final save even after the 3 s error auto-reset.
    private var pendingErrorMessage: String?

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
        isReplay = false
        replayHistoryId = nil
        pendingErrorMessage = nil
        transition(to: .recording)
        backend.setLanguage(env.language())
        env.resetHUDLevels()
        env.resetHUDTranscript()

        consume(backend.start())
    }

    /// Drains one session's event stream. Shared by start() and retranscribe().
    private func consume(_ stream: AsyncStream<RecordingEvent>) {
        sessionTask?.cancel()        // defensive: no overlapping consumer
        sessionTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .partial(let partial):
                    // Live: drop late partials once we've left .recording so a
                    // batch emitted just before stop() can't clobber the final.
                    // Replay: the whole session runs in .transcribing.
                    let live: RecordingStatus = self.isReplay ? .transcribing : .recording
                    guard self.status == live else { continue }
                    self.env.updateHUDTranscript(partial)
                case .audioLevel(let level):
                    self.env.pushHUDLevel(level)
                case .error(let message):
                    doushaLog("[RecordingController] recognition error: \(message)")
                    if self.status == .recording && !self.isReplay {
                        // Issue #46: engines dying must not end a live recording —
                        // the mic and the WAV don't need the network. Latch the
                        // failure and keep capturing until the user releases the
                        // key; handleFinal then archives the WAV and auto-rescues
                        // it. A capture failure (no audio at all) finishes the
                        // stream right after its error, which the loop exit below
                        // turns into the fatal transition.
                        self.pendingErrorMessage = message
                    } else {
                        // Intentionally NOT cancelling the consumer loop here: the stop()
                        // issued inside transitionToError produces a trailing .final
                        // (dropped by handleFinal's guard) and then finishes the stream,
                        // so the task exits on its own — parallel to the explicit
                        // sessionTask?.cancel() on the cancel() path.
                        self.transitionToError(message)
                    }
                case .final(let result):
                    self.handleFinal(result)
                }
            }
            // Stream over. One that dies while still .recording (capture failure:
            // .error then finish, no trailing .final ever) surfaces its latched
            // error now. Either way the latch is released — no trailing final is
            // coming, and holding it would wedge canRetranscribe.
            guard let self else { return }
            if self.status == .recording {
                self.transitionToError(self.pendingErrorMessage ?? "录音失败")
            }
            self.pendingErrorMessage = nil
        }
    }

    private func transitionToError(_ message: String) {
        if (status == .recording || status == .transcribing) && !isReplay {
            pendingErrorMessage = message
        }
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

    /// Whether a re-transcription may begin now. Mirrors start()'s guard: idle,
    /// or an error state (the failed-dictation rescue shouldn't wait out the
    /// 3 s auto-reset).
    var canRetranscribe: Bool {
        (status == .idle || isErrorStatus(status)) && pendingErrorMessage == nil
    }

    /// Re-transcribe a saved recording (menu bar / settings history pane).
    /// Runs the full engine pipeline against the WAV via a replay backend and
    /// puts the result on the clipboard instead of injecting. Entering
    /// .transcribing locks out the hotkey path (start() guards on idle) and the
    /// cancel key (recordingFlag stays false) for the whole replay.
    func retranscribe(id: String, url: URL) {
        guard canRetranscribe else {
            doushaLog("[RecordingController] retranscribe REJECTED (status=\(status))")
            return
        }
        // The Caches dir can be cleaned behind our back — fail loud, not silent.
        guard FileManager.default.fileExists(atPath: url.path) else {
            transitionToError("录音文件已丢失")
            return
        }
        doushaLog("[RecordingController] retranscribe start id=\(id)")
        let backend = env.makeReplayBackend(url)
        self.backend = backend
        sessionCorrect = env.makeCorrector()
        isReplay = true
        replayHistoryId = id
        transition(to: .transcribing)
        backend.setLanguage(env.language())
        env.resetHUDTranscript()
        consume(backend.start())
        // Safe immediately: MultiEngineBackend.stop() awaits its start task —
        // which includes the whole replay push — before finishing the engines.
        backend.stop()
    }

    /// Handles the terminal `.final` event. The `status == .transcribing` guard
    /// replaces the old generation check: a `.final` arriving after idle (e.g.
    /// post-cancel) is dropped. A `pendingErrorMessage` latch marks a live
    /// session whose engines all died; its final — whether it lands in
    /// .transcribing (engines died mid-recording, capture ran to the user's
    /// stop) or in the drop branch (engines died after stop; transitionToError's
    /// stop() yields the trailing .final after engine teardown) — arrives when
    /// the shared WAV is complete, the one point a failed recording can be
    /// archived and auto-rescued (issue #46).
    private func handleFinal(_ result: TranscriptionResult) {
        guard status == .transcribing else {
            if let message = pendingErrorMessage, !isReplay {
                pendingErrorMessage = nil
                archiveFailedAndRescue(
                    text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    message: message)
            }
            doushaLog("[RecordingController] final dropped (status=\(status))")
            return
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Issue #46: the engines all died mid-recording but capture ran to the
        // user's stop. Archive the completed WAV as a failed dictation and
        // auto-rescue it, instead of ending the session with a partial result.
        if let message = pendingErrorMessage, !isReplay {
            pendingErrorMessage = nil
            transition(to: .idle)
            archiveFailedAndRescue(text: text, message: message)
            return
        }
        guard !text.isEmpty else {
            // A silent live recording still enters history — "the ASR heard
            // nothing" is exactly when the user wants to re-transcribe.
            if !isReplay { _ = env.saveHistory("", nil) }
            transition(to: .idle)
            return
        }
        // QUA-264: local correction runs before the HUD final so what the user
        // sees is what gets injected. A correction that empties the text ends
        // the session quietly.
        let corrected = sessionCorrect(text)
        guard !corrected.isEmpty else {
            if !isReplay { _ = env.saveHistory(text, nil) }
            transition(to: .idle)
            return
        }
        // History stores the ASR transcript (pre-refine), matching what the
        // list shows and what a future re-transcription would compare against.
        if isReplay {
            if let id = replayHistoryId { env.updateHistory(id, corrected) }
        } else {
            _ = env.saveHistory(corrected, nil)
        }
        env.setFinalTranscript(corrected)
        refineAndInject(corrected)
    }

    /// Issue #46 auto-rescue: archive a dead-engines session (WAV complete,
    /// transcript partial or empty, `message` = the fatal engine error) and
    /// schedule one re-transcription of the entry just saved. Scheduled rather
    /// than called inline so the rescue's consume() never cancels the session
    /// task it is running on; result goes to the clipboard (replay semantics).
    /// If the rescue fails too, the red history entry remains for manual rescue.
    private func archiveFailedAndRescue(text: String, message: String) {
        guard let id = env.saveHistory(text, message) else { return }
        doushaLog("[RecordingController] auto-rescue id=\(id)")
        let rescue = env.rescue
        env.scheduleAfter(0) { rescue(id) }
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
        if isReplay {
            env.copyToClipboard(text)   // replay result never ⌘V-injects (spec)
        } else {
            env.inject(text)
        }
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
