import XCTest
import ASRSupport
import TalkerCommonSync
@testable import Dousha

/// Records every side effect the controller performs, so transition/lifecycle
/// tests can assert on order and arguments without a real HUD/audio/inject.
@MainActor
final class RecordingSpy {
    var statusLog: [RecordingStatus] = []        // applyStatusToHUD calls, in order
    var visibleLog: [Bool] = []                  // setHUDVisible calls
    var forceIdleCount = 0
    var resetLevelsCount = 0
    var resetTranscriptCount = 0
    var partials: [PartialTranscript] = []
    var levels: [Float] = []
    var finalTranscripts: [String] = []
    var injected: [String] = []
    var clipboardWrites: [String] = []
    var refineEnabled = false
    var refineMode: RefineMode = .immediate
    /// When set, immediate-refine returns this; nil means refine "failed" → raw kept.
    var refineResult: String??  = nil
    var language = "zh-CN"
    var madeBackends: [MockSpeechBackend] = []
    /// The flag Lock the controller owns (captured so the test can read the mirror).
    weak var flag: AnyObject?
}

/// SpeechBackend test double. Captures the callbacks the controller installs so
/// the test can fire partials/levels/errors and the stop completion on demand.
final class MockSpeechBackend: SpeechBackend, @unchecked Sendable {
    nonisolated(unsafe) private(set) var languageSet: String?
    nonisolated(unsafe) private(set) var startCalled = false
    nonisolated(unsafe) private(set) var stopCalled = false
    nonisolated(unsafe) private(set) var cancelCalled = false
    nonisolated(unsafe) var onPartial: (@Sendable (PartialTranscript) -> Void)?
    nonisolated(unsafe) var onAudioLevel: (@Sendable (Float) -> Void)?
    nonisolated(unsafe) var onError: (@Sendable (Error) -> Void)?
    nonisolated(unsafe) var stopCompletion: (@Sendable (TranscriptionResult) -> Void)?

    func setLanguage(_ identifier: String) { languageSet = identifier }
    func start(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
               onAudioLevel: @escaping @Sendable (Float) -> Void,
               onError: @escaping @Sendable (Error) -> Void) {
        startCalled = true
        self.onPartial = onPartial; self.onAudioLevel = onAudioLevel; self.onError = onError
    }
    func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        stopCalled = true; self.stopCompletion = completion
    }
    func cancel() { cancelCalled = true }
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
        applyStatusToHUD: { spy.statusLog.append($0) },
        setHUDVisible: { spy.visibleLog.append($0) },
        forceDispatcherIdle: { spy.forceIdleCount += 1 },
        resetHUDLevels: { spy.resetLevelsCount += 1 },
        resetHUDTranscript: { spy.resetTranscriptCount += 1 },
        updateHUDTranscript: { spy.partials.append($0) },
        pushHUDLevel: { spy.levels.append($0) },
        setFinalTranscript: { spy.finalTranscripts.append($0) },
        inject: { spy.injected.append($0) },
        isRefineEnabled: { spy.refineEnabled },
        refineMode: { spy.refineMode },
        refineImmediate: { text, done in
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

    func testPartialDuringRecording_updatesHUD() {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start()
        backend.onAudioLevel?(0.5)
        backend.onPartial?(PartialTranscript(finalText: "", interimText: "hi"))
        let exp = expectation(description: "main hop")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(spy.levels, [0.5])
        XCTAssertEqual(spy.partials.map(\.combined), ["hi"])
    }

    func testPartialAfterLeavingRecording_isDropped() {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start()
        c.testHook_transition(to: .transcribing)   // leave .recording without needing stop()
        backend.onPartial?(PartialTranscript(finalText: "", interimText: "late"))
        let exp = expectation(description: "main hop")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertTrue(spy.partials.isEmpty, "partials after .recording must be dropped")
    }

    func testError_transitionsToError_andReleasesBackend() {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start()
        backend.onError?(NSError(domain: "t", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "boom"]))
        let exp = expectation(description: "main hop")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(c.status, .error("boom"))
        XCTAssertTrue(backend.stopCalled, "error must release the mic via stop")
        XCTAssertEqual(spy.resetTranscriptCount, 2)  // once at start, once on error
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

    func testStop_emptyResult_returnsToIdle_noInject() {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start(); c.stop()
        fireStop(backend, text: "   ")
        XCTAssertEqual(c.status, .idle)
        XCTAssertTrue(spy.injected.isEmpty)
    }

    func testStop_withText_refineDisabled_injectsRawThenGreenFlashToIdle() {
        let backend = MockSpeechBackend()
        let (c, spy, sched) = makeSUT(backend: backend)
        spy.refineEnabled = false
        c.start(); c.stop()
        fireStop(backend, text: "hello world")
        XCTAssertEqual(spy.finalTranscripts, ["hello world"])
        XCTAssertEqual(spy.injected, ["hello world"])
        XCTAssertEqual(c.status, .injecting)
        sched.advance(by: 0.25)
        XCTAssertEqual(c.status, .idle)
    }

    func testStop_immediateRefine_injectsRefinedText() {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        spy.refineEnabled = true; spy.refineMode = .immediate
        spy.refineResult = .some("polished")
        c.start(); c.stop()
        fireStop(backend, text: "raw")
        XCTAssertEqual(spy.injected, ["polished"])
    }

    func testStop_deferredRefine_injectsRawAndRewritesClipboard() {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        spy.refineEnabled = true; spy.refineMode = .deferred
        spy.refineResult = .some("polished")
        c.start(); c.stop()
        fireStop(backend, text: "raw")
        XCTAssertEqual(spy.injected, ["raw"])
        XCTAssertEqual(spy.clipboardWrites, ["polished"])
    }

    func testStop_completionAfterCancel_isDropped() {
        let backend = MockSpeechBackend()
        let (c, spy, _) = makeSUT(backend: backend)
        c.start(); c.stop()
        c.testHook_bumpGenerationLikeCancel()
        fireStop(backend, text: "should be dropped")
        XCTAssertTrue(spy.injected.isEmpty)
        XCTAssertTrue(spy.finalTranscripts.isEmpty)
    }

    /// Fire the captured stop completion synchronously on main.
    private func fireStop(_ b: MockSpeechBackend, text: String) {
        let exp = expectation(description: "stop completion")
        b.stopCompletion?(TranscriptionResult(text: text, audioDuration: 1,
                                              lastResponseAge: nil, lastTranscriptAge: nil))
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
    }
}

@MainActor
final class RecordingControllerCancelTests: XCTestCase {

    func testCancel_fromRecording_cancelsBackend_andReturnsToIdle() {
        let backend = MockSpeechBackend()
        let (c, _, _) = makeSUT(backend: backend)
        c.start()
        c.cancel()
        XCTAssertTrue(backend.cancelCalled)
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

    func testCancel_bumpsGeneration_soLateBackendErrorIsDropped() {
        // cancel() bumps generation; an error from the now-superseded session
        // (captured the old generation) must be dropped, not flashed to the HUD.
        let backend = MockSpeechBackend()
        let (c, _, _) = makeSUT(backend: backend)
        c.start()
        c.cancel()                      // status .idle, generation advanced
        backend.onError?(NSError(domain: "t", code: 1,
                                 userInfo: [NSLocalizedDescriptionKey: "late boom"]))
        let exp = expectation(description: "main hop")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(c.status, .idle, "stale error after cancel must be dropped, not enter .error")
    }
}
