import XCTest
import Foundation
import ConcurrencySupport
@testable import MLXASR

private struct FakeLoadedMLXModel: MLXLoadedModel {
    let runPrewarm: @Sendable () async throws -> Void

    func prewarm() async throws { try await runPrewarm() }
    func prepareSession(language: String?) -> MLXPreparedSession {
        MLXPreparedSession(stream: FakeMLXStream()) { _ in "batch" }
    }
}

@MainActor
final class MLXModelPrewarmTests: XCTestCase {
    func testWarmupPrewarmsOffMainOnceAndKeepsCachedModel() async throws {
        let loads = Lock(0)
        let prewarms = Lock(0)
        let store = MLXModelStore { _ in
            loads.withLock { $0 += 1 }
            return FakeLoadedMLXModel {
                XCTAssertFalse(Thread.isMainThread)
                prewarms.withLock { $0 += 1 }
            }
        }
        await store.preload(MLXModelCatalog.defaultModel)
        await store.preload(MLXModelCatalog.defaultModel)
        let lease = try await store.acquireSessionLease()
        _ = try await store.load(MLXModelCatalog.defaultModel, lease: lease)
        await lease.release()
        XCTAssertEqual(loads.value(), 1)
        XCTAssertEqual(prewarms.value(), 1)
    }

    func testRecordingLoadAndWarmupJoiningThatLoadNeverPrewarm() async throws {
        let started = OneShotChannel<Void>()
        let finishLoad = OneShotChannel<Void>()
        let store = MLXModelStore { _ in
            started.finish(())
            try await finishLoad.wait()
            return FakeLoadedMLXModel { XCTFail("A recording-triggered load must never prewarm") }
        }
        let engine = MLXStreamingASR(store: store)
        await engine.prepareSession(onPartial: { _ in }, onError: { _ in XCTFail("Unexpected error") }, language: "zh-CN")
        engine.openStream()
        _ = try await started.wait()
        store.warmup(MLXModelCatalog.defaultModel)
        finishLoad.finish(())
        let completed = expectation(description: "recording finishes")
        engine.stop { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 2)
        await store.preload(MLXModelCatalog.defaultModel)
        let state = await store.state
        XCTAssertEqual(state, .ready(repoID: MLXModelCatalog.defaultModel.repoID))
    }

    func testPrewarmHoldsProcessLeaseUntilItReturns() async throws {
        let started = OneShotChannel<Void>()
        let finishPrewarm = OneShotChannel<Void>()
        let store = MLXModelStore { _ in
            FakeLoadedMLXModel {
                started.finish(())
                try await finishPrewarm.wait()
            }
        }
        store.warmup(MLXModelCatalog.defaultModel)
        _ = try await started.wait()
        let acquired = OneShotChannel<MLXSessionLease>(MLXSessionLease.self)
        let waiter = Task { acquired.finish(try await MLXModelStore().acquireSessionLease()) }
        if case .signaled = await acquired.wait(timeout: 0.03) {
            XCTFail("Prewarm released the process-wide lease before returning")
        }
        finishPrewarm.finish(())
        let lease = try await acquired.wait()
        await lease.release()
        _ = await waiter.result
    }

    func testPrewarmFailureLeavesReadyAndReleasesLease() async throws {
        let store = MLXModelStore { _ in
            FakeLoadedMLXModel { throw CancellationError() }
        }
        await store.preload(MLXModelCatalog.defaultModel)
        let state = await store.state
        XCTAssertEqual(state, .ready(repoID: MLXModelCatalog.defaultModel.repoID))
        let lease = try await store.acquireSessionLease()
        _ = try await store.load(MLXModelCatalog.defaultModel, lease: lease)
        await lease.release()
    }
}
