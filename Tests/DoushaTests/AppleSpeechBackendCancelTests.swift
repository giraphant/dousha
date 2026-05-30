import XCTest
@testable import Dousha
import DoubaoASR

final class AppleSpeechBackendCancelTests: XCTestCase {

    // MARK: - cancel before start

    func testCancel_onIdleBackend_isNoOp() {
        // The backend has never been started — cancel must not crash, must not
        // touch the audio engine in a way that throws, and must not fire any
        // callbacks (there are none to fire).
        let backend = AppleSpeechBackend(language: "en-US")
        backend.cancelSession()
        backend.cancelSession()   // idempotent
    }

    // MARK: - cancel without prior start — completion behaviour

    func testFinish_withoutStart_firesCompletionImmediatelyWithEmptyText() {
        // Document the existing contract that cancelSession() must not break:
        // calling finish() on an un-started backend hands an empty result back
        // synchronously (the early-return guard in finish()). This protects the
        // cleanup paths that finish the engine without a prior session.
        let backend = AppleSpeechBackend(language: "en-US")
        let exp = expectation(description: "finish completion")
        backend.finish { result in
            XCTAssertEqual(result.text, "")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - protocol conformance

    func testConformsToBufferCaptureEngine() {
        // Compile-time check via type assignment: AppleSpeechBackend must remain a
        // BufferCaptureEngine (the shared AudioTapHub pushes it native buffers via
        // ingest, and MultiEngineBackend drives it through cancelSession()). If the
        // conformance is removed or the impl drifts, this test stops compiling.
        let backend: BufferCaptureEngine = AppleSpeechBackend(language: "en-US")
        backend.cancelSession()
    }
}
