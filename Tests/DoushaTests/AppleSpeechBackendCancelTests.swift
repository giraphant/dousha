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
        backend.cancel()
        backend.cancel()   // idempotent
    }

    // MARK: - cancel without prior start — completion behaviour

    func testStop_withoutStart_firesCompletionImmediatelyWithEmptyText() {
        // Document the existing contract that cancel() must not break: calling
        // stop() on an un-started backend hands an empty result back synchronously
        // (the early-return guard in stop()). This protects callers like
        // AppDelegate.transitionToError that call speech.stop on the cleanup path.
        let backend = AppleSpeechBackend(language: "en-US")
        let exp = expectation(description: "stop completion")
        backend.stop { result in
            XCTAssertEqual(result.text, "")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func testRetranscribe_isNotSupportedAndReturnsNil() {
        let backend = AppleSpeechBackend(language: "en-US")
        let exp = expectation(description: "retranscribe completion")
        backend.retranscribeLastRecording { result in
            XCTAssertNil(result)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - protocol conformance

    func testConformsToSpeechBackend() {
        // Compile-time check via type assignment: AppleSpeechBackend must
        // implement the cancel() method added to SpeechBackend. If the protocol
        // requirement is removed or the impl drifts, this test stops compiling.
        let backend: SpeechBackend = AppleSpeechBackend(language: "en-US")
        backend.cancel()
    }
}
