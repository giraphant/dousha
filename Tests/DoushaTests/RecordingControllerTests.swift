import XCTest
import ASRSupport
import ConcurrencySupport
@testable import Dousha

/// Records every side effect the controller performs, so transition/lifecycle
/// tests can assert on order and arguments without a real HUD/audio/inject.
@MainActor
final class RecordingSpy {
    var statusLog: [RecordingStatus] = []        // applyStatusToHUD calls, in order
    var visibleLog: [Bool] = []                  // setHUDVisible calls
    var cancelKeyEnabledLog: [Bool] = []
    var forceIdleCount = 0
    var resetLevelsCount = 0
    var resetTranscriptCount = 0
    var partials: [PartialTranscript] = []
    var levels: [Float] = []
    var finalTranscripts: [String] = []
    var injected: [String] = []
    var clipboardWrites: [String] = []
    var replayURLs: [URL] = []
    var clipboardCopies: [String] = []
    var savedHistory: [(transcript: String, error: String?)] = []
    /// Id saveHistory reports back (nil = archiving failed → no auto-rescue).
    var saveHistoryId: String? = "h-saved"
    var rescues: [String] = []                   // auto-rescue ids, in order
    var historyUpdates: [(id: String, transcript: String)] = []
    /// QUA-264 correction seam: inputs seen, and the transform applied (identity
    /// by default so unrelated tests are unaffected). The transform is captured
    /// by makeCorrector at start(), mirroring production's config snapshot.
    var correctionInputs: [String] = []
    var correctionTransform: (String) -> String = { $0 }
    /// Text handed to refineImmediate (to assert the refiner sees corrected text).
    var refineInputs: [String] = []
    var refineEnabled = false
    var refineMode: RefineMode = .immediate
    /// When set, immediate-refine returns this; nil means refine "failed" → raw kept.
    var refineResult: String??  = nil
    var language = "zh-CN"
    var madeBackends: [MockSpeechBackend] = []
    /// The flag Lock the controller owns (captured so the test can read the mirror).
    weak var flag: AnyObject?
}

/// SpeechBackend test double. `start()` hands back a stream and stores its
/// continuation so a test can drive events on demand; `stop()`/`cancel()` record
/// the call (and `cancel()` finishes the stream, matching production).
final class MockSpeechBackend: SpeechBackend, @unchecked Sendable {
    nonisolated(unsafe) private(set) var languageSet: String?
    nonisolated(unsafe) private(set) var startCalled = false
    nonisolated(unsafe) private(set) var stopCalled = false
    nonisolated(unsafe) private(set) var cancelCalled = false
    nonisolated(unsafe) private var continuation: AsyncStream<RecordingEvent>.Continuation?

    func setLanguage(_ identifier: String) { languageSet = identifier }

    func start() -> AsyncStream<RecordingEvent> {
        startCalled = true
        let (stream, cont) = AsyncStream<RecordingEvent>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        return stream
    }
    func stop() { stopCalled = true }
    func cancel() { cancelCalled = true; continuation?.finish() }

    // Test drivers — yield events into the live stream.
    func emitPartial(_ p: PartialTranscript) { continuation?.yield(.partial(p)) }
    func emitLevel(_ l: Float) { continuation?.yield(.audioLevel(l)) }
    func emitError(_ message: String) { continuation?.yield(.error(message)) }
    func emitFinal(_ r: TranscriptionResult) { continuation?.yield(.final(r)); continuation?.finish() }
    /// Finish the stream with no trailing final (capture failure in production).
    func endStream() { continuation?.finish() }
}

/// Deterministic clock + scheduler. `advance` fires every work item whose
/// deadline has passed, in scheduled order.
@MainActor
final class ManualScheduler {
    private(set) var now = Date(timeIntervalSince1970: 1_000)
    private var pending: [(deadline: Date, work: () -> Void)] = []
    func nowProvider() -> Date { now }
    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        pending.append((now.addingTimeInterval(delay), work))
    }
    /// Advance the clock and run any work that is now due (in deadline order).
    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        let due = pending.filter { $0.deadline <= now }.sorted { $0.deadline < $1.deadline }
        pending.removeAll { $0.deadline <= now }
        due.forEach { $0.work() }
    }
    var pendingCount: Int { pending.count }
}

/// Builds a controller wired to a spy + manual scheduler, returning all three.
/// `backend` is the MockSpeechBackend that makeBackend() will hand out next.
@MainActor
func makeSUT(backend: MockSpeechBackend = MockSpeechBackend())
    -> (RecordingController, RecordingSpy, ManualScheduler) {
    let spy = RecordingSpy()
    let sched = ManualScheduler()
    let env = RecordingEnvironment(
        makeBackend: { spy.madeBackends.append(backend); return backend },
        makeReplayBackend: { url in
            spy.replayURLs.append(url)
            spy.madeBackends.append(backend)
            return backend
        },
        copyToClipboard: { spy.clipboardCopies.append($0) },
        saveHistory: { transcript, error in
            spy.savedHistory.append((transcript, error))
            return spy.saveHistoryId
        },
        updateHistory: { id, transcript in spy.historyUpdates.append((id, transcript)) },
        rescue: { id in spy.rescues.append(id) },
        applyStatusToHUD: { spy.statusLog.append($0) },
        setHUDVisible: { spy.visibleLog.append($0) },
        setCancelKeyEnabled: { spy.cancelKeyEnabledLog.append($0) },
        forceDispatcherIdle: { spy.forceIdleCount += 1 },
        resetHUDLevels: { spy.resetLevelsCount += 1 },
        resetHUDTranscript: { spy.resetTranscriptCount += 1 },
        updateHUDTranscript: { spy.partials.append($0) },
        pushHUDLevel: { spy.levels.append($0) },
        setFinalTranscript: { spy.finalTranscripts.append($0) },
        makeCorrector: {
            let transform = spy.correctionTransform   // snapshot, like production
            return { spy.correctionInputs.append($0); return transform($0) }
        },
        inject: { spy.injected.append($0) },
        isRefineEnabled: { spy.refineEnabled },
        refineMode: { spy.refineMode },
        refineImmediate: { text, done in
            spy.refineInputs.append(text)
            if let r = spy.refineResult { done(r) } else { done(nil) }
        },
        refineLater: { text in if let r = spy.refineResult ?? nil { spy.clipboardWrites.append(r) } },
        language: { spy.language },
        now: sched.nowProvider,
        scheduleAfter: sched.schedule
    )
    let controller = RecordingController(environment: env)
    spy.flag = controller.recordingFlag
    return (controller, spy, sched)
}

/// Polls `cond` on the main actor until true or `timeout`, yielding the actor so
/// the controller's stream-consumer task can run. Replaces the old
/// `expectation + DispatchQueue.main.async` flush, which doesn't reliably order
/// after AsyncStream delivery.
@MainActor
func expectEventually(_ cond: @escaping () -> Bool,
                      _ message: String = "",
                      timeout: TimeInterval = 1,
                      file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !cond() {
        if Date() > deadline { XCTFail("timed out waiting: \(message)", file: file, line: line); return }
        try? await Task.sleep(nanoseconds: 1_000_000)   // 1ms
    }
}

@MainActor
final class RecordingControllerTransitionTests: XCTestCase {

    func testToRecording_setsFlagThenHUDStatus_andShowsHUD() {
        let (c, spy, _) = makeSUT()
        c.testHook_transition(to: .recording)
        XCTAssertEqual((spy.flag as? Lock<Bool>)?.value(), true)
        XCTAssertEqual(spy.statusLog, [.recording])
        XCTAssertEqual(spy.visibleLog, [true])
        XCTAssertEqual(spy.forceIdleCount, 0)
    }

    func testToIdleFromRecording_forcesDispatcherIdle_andHidesHUD() {
        let (c, spy, _) = makeSUT()
        c.testHook_transition(to: .recording)
        c.testHook_transition(to: .idle)
        XCTAssertEqual((spy.flag as? Lock<Bool>)?.value(), false)
        XCTAssertEqual(spy.statusLog, [.recording, .idle])
        XCTAssertEqual(spy.visibleLog, [true, false])
        XCTAssertEqual(spy.forceIdleCount, 1)
    }

    func testInteriorTransition_doesNotReFlipVisibility() {
        let (c, spy, _) = makeSUT()
        c.testHook_transition(to: .recording)
        c.testHook_transition(to: .transcribing)
        c.testHook_transition(to: .injecting)
        XCTAssertEqual(spy.visibleLog, [true])
    }

    func testCancelKeyTap_enabledOnlyWhileRecording() {
        let (c, spy, _) = makeSUT()
        c.testHook_transition(to: .recording)
        c.testHook_transition(to: .transcribing)
        c.testHook_transition(to: .injecting)
        c.testHook_transition(to: .idle)
        XCTAssertEqual(spy.cancelKeyEnabledLog, [true, false, false, false])
    }
}

@MainActor
final class RecordingControllerStartTests: XCTestCase {

    func testStart_fromIdle_buildsBackend_resetsHUD_entersRecording() {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start()
        XCTAssertEqual(spy.madeBackends.count, 1)
        XCTAssertEqual(backend.languageSet, "zh-CN")
        XCTAssertTrue(backend.startCalled)
        XCTAssertEqual(spy.resetLevelsCount, 1)
        XCTAssertEqual(spy.resetTranscriptCount, 1)
        XCTAssertEqual(c.status, .recording)
    }

    func testStart_fromRecording_isRejected() {
        let (c, spy, _) = makeSUT()
        c.start()
        c.start()
        XCTAssertEqual(spy.madeBackends.count, 1)
        XCTAssertEqual(c.status, .recording)
    }

    func testStart_fromError_isAccepted() {
        let (c, _, _) = makeSUT()
        c.testHook_transition(to: .error("boom"))
        c.start()
        XCTAssertEqual(c.status, .recording)
    }

    func testStart_withinTeardownGuard_defersThenProceeds() {
        let (c, spy, sched) = makeSUT()
        c.start()
        c.cancel()
        XCTAssertEqual(c.status, .idle)
        let backendsAfterCancel = spy.madeBackends.count
        c.start()
        XCTAssertEqual(c.status, .idle, "start within guard window must defer")
        XCTAssertEqual(spy.madeBackends.count, backendsAfterCancel, "no backend built yet")
        XCTAssertEqual(sched.pendingCount, 1, "a retry was scheduled")
        sched.advance(by: 0.25)
        XCTAssertEqual(c.status, .recording)
        XCTAssertEqual(spy.madeBackends.count, backendsAfterCancel + 1)
    }
}

@MainActor
final class RecordingControllerCallbackTests: XCTestCase {

    func testPartialDuringRecording_updatesHUD() async {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start()
        backend.emitLevel(0.5)
        backend.emitPartial(PartialTranscript(finalText: "", interimText: "hi"))
        await expectEventually({ spy.partials.map(\.combined) == ["hi"] }, "partial delivered")
        XCTAssertEqual(spy.levels, [0.5])
    }

    func testPartialAfterLeavingRecording_isDropped() async {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start()
        c.testHook_transition(to: .transcribing)   // leave .recording without stop()
        backend.emitPartial(PartialTranscript(finalText: "", interimText: "late"))
        // Sentinel: audio levels are NOT status-gated, so this is always delivered.
        // FIFO + serial loop ⇒ once the level is observed, the earlier partial has
        // already been processed (and dropped) — no timing dependency.
        backend.emitLevel(0.9)
        await expectEventually({ spy.levels == [0.9] }, "sentinel level delivered")
        XCTAssertTrue(spy.partials.isEmpty, "partials after .recording must be dropped")
    }

    func testErrorDuringRecording_keepsCapturing() async {
        // Issue #46: engines all dying must not end a live recording — the mic
        // and the WAV don't need the network. The error is latched; capture
        // runs until the user releases the key.
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start()
        backend.emitError("boom")
        // FIFO + serial loop ⇒ once the sentinel level is observed, the earlier
        // error has already been processed (same idiom as the late-partial test).
        backend.emitLevel(0.9)
        await expectEventually({ spy.levels == [0.9] }, "sentinel level delivered")
        XCTAssertEqual(c.status, .recording, "engines dead must not end a live recording")
        XCTAssertFalse(backend.stopCalled, "capture must keep running until the user stops")
        XCTAssertFalse(c.canRetranscribe)
    }

    func testErrorDuringTranscribing_transitionsToError() async {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start(); c.stop()
        backend.emitError("boom")
        await expectEventually({ c.status == .error("boom") }, "error transition")
        XCTAssertEqual(spy.resetTranscriptCount, 2)  // once at start, once on error
    }

    func testCaptureFailure_streamEndsWhileRecording_entersError() async {
        // A stream that dies while still .recording (capture failure: .error
        // then finish, no trailing final ever) must surface the fatal error and
        // release the retranscribe gate.
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start()
        backend.emitError("mic broke")
        backend.endStream()
        await expectEventually({ c.status == .error("mic broke") }, "capture failure is fatal")
        XCTAssertTrue(c.canRetranscribe, "latch must release — no trailing final is coming")
        XCTAssertTrue(spy.savedHistory.isEmpty, "no WAV exists to archive")
    }
}

@MainActor
final class RecordingControllerStopTests: XCTestCase {

    func testStop_fromRecording_entersTranscribing() {
        let backend = MockSpeechBackend()
        let (c, _, _) = makeSUT(backend: backend)
        c.start()
        c.stop()
        XCTAssertEqual(c.status, .transcribing)
        XCTAssertTrue(backend.stopCalled)
    }

    func testStop_notRecording_isRejected() {
        let backend = MockSpeechBackend()
        let (c, _, _) = makeSUT(backend: backend)
        c.stop()
        XCTAssertFalse(backend.stopCalled)
        XCTAssertEqual(c.status, .idle)
    }

    func testStop_emptyResult_returnsToIdle_noInject() async {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start(); c.stop()
        backend.emitFinal(result(text: "   "))
        await expectEventually({ c.status == .idle }, "empty result returns to idle")
        XCTAssertTrue(spy.injected.isEmpty)
    }

    func testStop_withText_refineDisabled_injectsRawThenGreenFlashToIdle() async {
        let backend = MockSpeechBackend()
        let (c, spy, sched) = makeSUT(backend: backend)
        spy.refineEnabled = false
        c.start(); c.stop()
        backend.emitFinal(result(text: "hello world"))
        await expectEventually({ spy.injected == ["hello world"] }, "raw injected")
        XCTAssertEqual(spy.finalTranscripts, ["hello world"])
        XCTAssertEqual(c.status, .injecting)
        sched.advance(by: 0.25)
        XCTAssertEqual(c.status, .idle)
    }

    func testStop_correctionAppliesBeforeHUDFinalAndInject() async {
        // QUA-264: the corrected text (not the raw final) must reach both the
        // HUD final transcript and the injector, and the refiner sees it too.
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        spy.correctionTransform = { $0.replacingOccurrences(of: "json", with: "JSON") }
        c.start(); c.stop()
        backend.emitFinal(result(text: "check the json"))
        await expectEventually({ spy.injected == ["check the JSON"] }, "corrected text injected")
        XCTAssertEqual(spy.correctionInputs, ["check the json"])
        XCTAssertEqual(spy.finalTranscripts, ["check the JSON"])
    }

    func testStop_refinerReceivesCorrectedText() async {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        spy.refineEnabled = true; spy.refineMode = .immediate
        spy.refineResult = .some(nil)   // refine "fails" → corrected text injected
        spy.correctionTransform = { $0.uppercased() }
        c.start(); c.stop()
        backend.emitFinal(result(text: "raw"))
        await expectEventually({ spy.injected == ["RAW"] }, "corrected text injected on refine failure")
        XCTAssertEqual(spy.refineInputs, ["RAW"])   // refiner saw corrected, not raw
    }

    func testStop_correctionConfigIsSnapshottedAtStart() async {
        // Changing the correction config mid-recording must not affect the live
        // session — same invariant as the engines' glossary snapshot.
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        spy.correctionTransform = { _ in "from-start-config" }
        c.start()
        spy.correctionTransform = { _ in "from-mid-recording-config" }
        c.stop()
        backend.emitFinal(result(text: "raw"))
        await expectEventually({ spy.injected == ["from-start-config"] },
                               "start-time correction config used")
    }

    func testStop_correctionEmptiesText_returnsToIdle_noInject() async {
        // A rule set that deletes the whole utterance ends the session quietly.
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        spy.correctionTransform = { _ in "" }
        c.start(); c.stop()
        backend.emitFinal(result(text: "嗯"))
        await expectEventually({ c.status == .idle }, "emptied result returns to idle")
        XCTAssertTrue(spy.injected.isEmpty)
        XCTAssertTrue(spy.finalTranscripts.isEmpty)
    }

    func testStop_immediateRefine_injectsRefinedText() async {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        spy.refineEnabled = true; spy.refineMode = .immediate
        spy.refineResult = .some("polished")
        c.start(); c.stop()
        backend.emitFinal(result(text: "raw"))
        await expectEventually({ spy.injected == ["polished"] }, "refined injected")
    }

    func testStop_deferredRefine_injectsRawAndRewritesClipboard() async {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        spy.refineEnabled = true; spy.refineMode = .deferred
        spy.refineResult = .some("polished")
        c.start(); c.stop()
        backend.emitFinal(result(text: "raw"))
        await expectEventually({ spy.injected == ["raw"] && spy.clipboardWrites == ["polished"] },
                               "raw injected + clipboard rewritten")
    }

    func testCancel_thenLateFinal_isDropped() async {
        // After cancel() the stream is finished; a late .final is a no-op yield.
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start()
        c.cancel()
        // cancel() finished the stream; yielding to a finished continuation is a
        // contractual no-op, so this late emit can never be delivered.
        backend.emitFinal(result(text: "should be dropped"))
        XCTAssertTrue(spy.injected.isEmpty)
        XCTAssertTrue(spy.finalTranscripts.isEmpty)
    }

    private func result(text: String) -> TranscriptionResult {
        TranscriptionResult(text: text)
    }
}

@MainActor
final class RecordingControllerCancelTests: XCTestCase {

    func testCancel_fromRecording_cancelsBackend_andReturnsToIdle() {
        let backend = MockSpeechBackend()
        let (c, _, _) = makeSUT(backend: backend)
        c.start()
        XCTAssertTrue(c.testHook_hasBackend)
        c.cancel()
        XCTAssertTrue(backend.cancelCalled)
        XCTAssertFalse(c.testHook_hasBackend)
        XCTAssertEqual(c.status, .idle)
    }

    func testCancel_notRecording_isNoOp() {
        let backend = MockSpeechBackend()
        let (c, _, _) = makeSUT(backend: backend)
        c.cancel()                      // from idle
        XCTAssertFalse(backend.cancelCalled)
        XCTAssertEqual(c.status, .idle)
    }

    func testCancel_duringTranscribing_isRejected() {
        let backend = MockSpeechBackend()
        let (c, _, _) = makeSUT(backend: backend)
        c.start(); c.stop()             // now .transcribing
        c.cancel()                      // cancel only valid in .recording
        XCTAssertFalse(backend.cancelCalled)
        XCTAssertEqual(c.status, .transcribing)
    }

    func testCancel_thenLateError_isDropped() async {
        // cancel() finishes the stream; a late .error from the superseded session
        // is a no-op yield and must not flash the HUD red.
        let backend = MockSpeechBackend()
        let (c, _, _) = makeSUT(backend: backend)
        c.start()
        c.cancel()                      // status .idle, stream finished
        // cancel() finished the stream; yielding to a finished continuation is a
        // contractual no-op, so this late emit can never be delivered.
        backend.emitError("late boom")
        XCTAssertEqual(c.status, .idle, "stale error after cancel must be dropped, not enter .error")
    }
}

@MainActor
final class RecordingControllerRetranscribeTests: XCTestCase {

    /// Creates an empty temp file so retranscribe's existence check passes.
    private func makeTempWAV() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 44))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRetranscribe_runsReplayToClipboardAndUpdatesHistory() async {
        let backend = MockSpeechBackend()
        let (c, spy, sched) = makeSUT(backend: backend)
        let url = makeTempWAV()

        c.retranscribe(id: "h1", url: url)
        XCTAssertEqual(c.status, .transcribing)
        XCTAssertEqual(spy.replayURLs, [url])
        XCTAssertTrue(backend.startCalled)
        XCTAssertTrue(backend.stopCalled)

        // Replay partials arrive while .transcribing and must reach the HUD.
        backend.emitPartial(PartialTranscript(finalText: "部分", interimText: ""))
        await expectEventually({ spy.partials.count == 1 }, "replay partial delivered")

        backend.emitFinal(TranscriptionResult(text: "重转结果"))
        await expectEventually({ c.status == .injecting }, "replay final -> injecting")
        XCTAssertEqual(spy.clipboardCopies, ["重转结果"])
        XCTAssertTrue(spy.injected.isEmpty)                       // never ⌘V on replay
        XCTAssertEqual(spy.historyUpdates.map(\.id), ["h1"])
        XCTAssertEqual(spy.historyUpdates.map(\.transcript), ["重转结果"])
        XCTAssertTrue(spy.savedHistory.isEmpty)                   // replay adds no new entry
        sched.advance(by: RecordingController.injectGreenFlash)
        XCTAssertEqual(c.status, .idle)
    }

    func testRetranscribe_rejectedWhileRecording() {
        let (c, spy, _) = makeSUT()
        c.start()
        XCTAssertEqual(c.status, .recording)
        c.retranscribe(id: "h1", url: makeTempWAV())
        XCTAssertTrue(spy.replayURLs.isEmpty)
        XCTAssertEqual(c.status, .recording)
    }

    func testRetranscribe_missingFileGoesToError() {
        let (c, spy, _) = makeSUT()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).wav")
        c.retranscribe(id: "h1", url: missing)
        guard case .error = c.status else { return XCTFail("expected .error, got \(c.status)") }
        XCTAssertTrue(spy.replayURLs.isEmpty)
    }

    func testStartRejectedDuringReplay() {
        let (c, spy, _) = makeSUT()
        c.retranscribe(id: "h1", url: makeTempWAV())
        XCTAssertEqual(c.status, .transcribing)
        c.start()
        XCTAssertEqual(c.status, .transcribing)
        XCTAssertEqual(spy.madeBackends.count, 1)   // only the replay backend
    }

    func testLiveFinal_savesHistoryWithCorrectedText() async {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        spy.correctionTransform = { $0 + "。" }
        c.start()
        c.stop()
        backend.emitFinal(TranscriptionResult(text: "你好"))
        await expectEventually({ !spy.savedHistory.isEmpty }, "live final saves history")
        XCTAssertEqual(spy.savedHistory[0].transcript, "你好。")
        XCTAssertNil(spy.savedHistory[0].error)
        XCTAssertTrue(spy.historyUpdates.isEmpty)
    }

    func testLiveEmptyFinal_stillSavesHistory() async {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start()
        c.stop()
        backend.emitFinal(TranscriptionResult(text: "  "))
        await expectEventually({ !spy.savedHistory.isEmpty }, "empty final still saves history")
        XCTAssertEqual(spy.savedHistory[0].transcript, "")
        XCTAssertEqual(c.status, .idle)
    }

    func testLiveErrorAfterStop_trailingFinalSavesHistoryWithError() async {
        // Engines die AFTER the user released the key (.transcribing): still
        // the fatal-error path; the trailing final archives + auto-rescues.
        let backend = MockSpeechBackend()
        let (c, spy, sched) = makeSUT(backend: backend)
        spy.saveHistoryId = "h-late"
        c.start(); c.stop()
        backend.emitError("network down")
        await expectEventually({ c.status != .transcribing }, "error transition")
        // The stop() inside transitionToError later yields a trailing final.
        backend.emitFinal(TranscriptionResult(text: "残余"))
        await expectEventually({ !spy.savedHistory.isEmpty }, "trailing final saves history with error")
        XCTAssertEqual(spy.savedHistory[0].transcript, "残余")
        XCTAssertEqual(spy.savedHistory[0].error, "network down")
        sched.advance(by: 0)
        XCTAssertEqual(spy.rescues, ["h-late"], "failed session auto-rescues its entry")
    }

    // MARK: - Issue #46: engines die mid-recording — capture continues to the
    // user's stop, the final archives the WAV, and a rescue is scheduled.

    func testErrorDuringRecording_stopArchivesAndAutoRescues() async {
        let backend = MockSpeechBackend()
        let (c, spy, sched) = makeSUT(backend: backend)
        spy.saveHistoryId = "h-rescue"
        c.start()
        backend.emitError("network down")
        backend.emitLevel(0.9)   // sentinel: error processed once level lands
        await expectEventually({ spy.levels == [0.9] }, "error processed")
        XCTAssertEqual(c.status, .recording)

        c.stop()                 // user releases the key — WAV is complete
        XCTAssertEqual(c.status, .transcribing)
        backend.emitFinal(TranscriptionResult(text: "残余"))
        await expectEventually({ !spy.savedHistory.isEmpty }, "final archives the failed dictation")
        XCTAssertEqual(spy.savedHistory[0].transcript, "残余")
        XCTAssertEqual(spy.savedHistory[0].error, "network down")
        XCTAssertEqual(c.status, .idle)
        XCTAssertTrue(spy.injected.isEmpty, "a failed dictation must not inject")
        XCTAssertTrue(spy.finalTranscripts.isEmpty)

        sched.advance(by: 0)
        XCTAssertEqual(spy.rescues, ["h-rescue"], "the just-saved entry is auto-rescued")
    }

    func testErrorDuringRecording_archiveFails_noRescue() async {
        let backend = MockSpeechBackend()
        let (c, spy, sched) = makeSUT(backend: backend)
        spy.saveHistoryId = nil   // history save failed → nothing to rescue
        c.start()
        backend.emitError("network down")
        backend.emitLevel(0.9)
        await expectEventually({ spy.levels == [0.9] }, "error processed")
        c.stop()
        backend.emitFinal(TranscriptionResult(text: ""))
        await expectEventually({ c.status == .idle }, "session ends")
        sched.advance(by: 0)
        XCTAssertTrue(spy.rescues.isEmpty)
    }

    func testErrorDuringRecording_cancelDiscardsEverything() async {
        let backend = MockSpeechBackend()
        let (c, spy, sched) = makeSUT(backend: backend)
        c.start()
        backend.emitError("network down")
        backend.emitLevel(0.9)
        await expectEventually({ spy.levels == [0.9] }, "error processed")
        c.cancel()
        await expectEventually({ c.canRetranscribe }, "latch released at stream end")
        XCTAssertEqual(c.status, .idle)
        sched.advance(by: 0)
        XCTAssertTrue(spy.savedHistory.isEmpty)
        XCTAssertTrue(spy.rescues.isEmpty)
    }

    func testCancel_savesNothing() {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start()
        c.cancel()
        XCTAssertTrue(spy.savedHistory.isEmpty)
    }

    // MARK: - Error-window race (the trailing .final that archives a failed
    // LIVE session hasn't arrived yet — canRetranscribe must stay false so a
    // rescue can't destroy the very recording it wants).

    func testRetranscribe_blockedUntilTrailingFinalArrives() async {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start(); c.stop()
        backend.emitError("boom")
        await expectEventually({ c.status != .transcribing }, "error transition")
        XCTAssertFalse(c.canRetranscribe, "gate must hold until the trailing final archives the entry")

        c.retranscribe(id: "h1", url: makeTempWAV())
        XCTAssertTrue(spy.replayURLs.isEmpty, "retranscribe must be rejected while the gate is closed")

        backend.emitFinal(TranscriptionResult(text: "残余"))
        await expectEventually({ !spy.savedHistory.isEmpty && c.canRetranscribe },
                               "trailing final archives the entry and opens the gate")

        c.retranscribe(id: "h1", url: makeTempWAV())
        XCTAssertEqual(c.status, .transcribing)
    }

    func testTrailingFinalAfterErrorAutoReset_stillSaves() async {
        let backend = MockSpeechBackend()
        let (c, spy, sched) = makeSUT(backend: backend)
        c.start(); c.stop()
        backend.emitError("network down")
        await expectEventually({ c.status == .error("network down") }, "error transition")

        sched.advance(by: RecordingController.errorAutoReset)
        XCTAssertEqual(c.status, .idle, "auto-reset must fire even with the gate still held")

        backend.emitFinal(TranscriptionResult(text: "残余"))
        await expectEventually({ !spy.savedHistory.isEmpty },
                               "trailing final still saves after the auto-reset lands in .idle")
        XCTAssertEqual(spy.savedHistory.count, 1)
        XCTAssertEqual(spy.savedHistory[0].transcript, "残余")
        XCTAssertEqual(spy.savedHistory[0].error, "network down")
    }

    func testReplayEmptyFinal_writesNoHistory() async {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.retranscribe(id: "h1", url: makeTempWAV())
        backend.emitFinal(TranscriptionResult(text: "  "))
        await expectEventually({ c.status == .idle }, "empty replay result returns to idle")
        XCTAssertTrue(spy.savedHistory.isEmpty)
        XCTAssertTrue(spy.historyUpdates.isEmpty)
        XCTAssertTrue(spy.clipboardCopies.isEmpty)
    }

    func testReplayError_writesNoHistory() async {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.retranscribe(id: "h1", url: makeTempWAV())
        backend.emitError("replay boom")
        await expectEventually({ c.status != .transcribing }, "replay error transition")

        backend.emitFinal(TranscriptionResult(text: "残余"))
        // The drop branch is a no-op for a replay error (no pendingErrorMessage,
        // no status change) — give the consumer loop a few ticks to actually run
        // it before asserting the negative (mirrors AudioTapHub's drain idiom).
        for _ in 0..<4 { await Task.yield() }
        XCTAssertTrue(spy.savedHistory.isEmpty)
        XCTAssertTrue(spy.historyUpdates.isEmpty)
    }
}
