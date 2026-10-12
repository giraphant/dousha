import XCTest
import Foundation
import ConcurrencySupport
import ASRSupport
@testable import MLXASR

@MainActor
final class MLXASRLifecycleTests: XCTestCase {
    private enum LoadFailure: LocalizedError {
        case offline
        var errorDescription: String? { "offline test failure" }
    }

    func testStopDuringFailedSetupDeliversErrorAndOneMainThreadCompletion() async {
        let started = OneShotChannel<Void>()
        let failLoad = OneShotChannel<Void>()
        let store = MLXModelStore { _ in
            started.finish(())
            try await failLoad.wait()
            throw LoadFailure.offline
        }
        let engine = MLXStreamingASR(store: store)
        let errorDelivered = expectation(description: "load failure delivered")
        let completed = expectation(description: "completed exactly once")
        let completionCount = Lock(0)
        await engine.prepareSession(onPartial: { _ in XCTFail("Failed setup cannot emit partials") }, onError: { error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(error as? MLXASRError, .modelLoadFailed("offline test failure"))
            errorDelivered.fulfill()
        }, language: "auto")
        engine.ingest(Data([0x00, 0x40]))
        engine.openStream()
        guard case .signaled = await started.wait(timeout: 1) else {
            XCTFail("Setup did not invoke the injected loader")
            engine.cancel()
            failLoad.finish(())
            return
        }
        let loadingState = await store.state
        XCTAssertEqual(loadingState, .loading(repoID: MLXModelCatalog.defaultModel.repoID))
        let completion: @Sendable (TranscriptionResult) -> Void = { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result.text, "")
            XCTAssertNotNil(result.traceId)
            completionCount.withLock { $0 += 1 }
            completed.fulfill()
        }
        engine.stop(completion: completion)
        engine.stop(completion: completion)
        failLoad.finish(())
        await fulfillment(of: [errorDelivered, completed], timeout: 2)
        XCTAssertEqual(completionCount.value(), 1)
        let failedState = await store.state
        XCTAssertEqual(failedState, .failed(repoID: MLXModelCatalog.defaultModel.repoID, message: "offline test failure"))
    }

    func testCancelDuringLoadSuppressesCallbacksAndEventuallyReleasesLease() async throws {
        let started = OneShotChannel<Void>()
        let failLoad = OneShotChannel<Void>()
        let store = MLXModelStore { _ in
            started.finish(())
            try await failLoad.wait()
            throw LoadFailure.offline
        }
        let engine = MLXStreamingASR(store: store)
        let unexpected = expectation(description: "cancelled recording emits no callbacks")
        unexpected.isInverted = true
        await engine.prepareSession(onPartial: { _ in unexpected.fulfill() },
                                    onError: { _ in unexpected.fulfill() }, language: "en-US")
        engine.openStream()
        guard case .signaled = await started.wait(timeout: 1) else {
            XCTFail("Setup did not invoke the injected loader")
            engine.cancel()
            failLoad.finish(())
            return
        }
        engine.cancel()
        engine.cancel()
        engine.stop { _ in unexpected.fulfill() }
        failLoad.finish(())
        // Reacquiring the process lease proves cancelled setup relinquished it
        // after the non-cancellable shared load settled; no model was created.
        let lease = try await store.acquireSessionLease()
        await lease.release()
        await fulfillment(of: [unexpected], timeout: 0.05)
    }

    func testRestartWhileLoadIsPendingQuarantinesOldGeneration() async throws {
        let firstStarted = OneShotChannel<Void>()
        let failFirst = OneShotChannel<Void>()
        let loads = Lock(0)
        let store = MLXModelStore { _ in
            let attempt = loads.withLock { $0 += 1; return $0 }
            if attempt == 1 {
                firstStarted.finish(())
                try await failFirst.wait()
            }
            throw LoadFailure.offline
        }
        let engine = MLXStreamingASR(store: store)
        let oldCallback = expectation(description: "old generation is silent")
        oldCallback.isInverted = true
        await engine.prepareSession(onPartial: { _ in oldCallback.fulfill() },
                                    onError: { _ in oldCallback.fulfill() }, language: "zh-CN")
        engine.openStream()
        guard case .signaled = await firstStarted.wait(timeout: 1) else {
            XCTFail("First setup did not reach the injected loader")
            engine.cancel()
            failFirst.finish(())
            return
        }
        engine.stop { _ in oldCallback.fulfill() }
        let newError = expectation(description: "new recording receives its own error")
        let newCompletion = expectation(description: "new recording completes")
        await engine.prepareSession(onPartial: { _ in XCTFail("No model exists") },
                                    onError: { _ in newError.fulfill() }, language: "auto")
        engine.openStream()
        engine.stop { result in
            XCTAssertEqual(result.text, "")
            newCompletion.fulfill()
        }
        failFirst.finish(())
        await fulfillment(of: [newError, newCompletion], timeout: 2)
        await fulfillment(of: [oldCallback], timeout: 0.05)
        XCTAssertEqual(loads.value(), 2)
    }
}
