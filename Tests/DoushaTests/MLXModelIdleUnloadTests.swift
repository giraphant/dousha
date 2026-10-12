import XCTest
import ConcurrencySupport
@testable import MLXASR

private final class IdleUnloadModel: MLXLoadedModel {
    let onDrop: @Sendable () -> Void
    init(onDrop: @escaping @Sendable () -> Void = {}) { self.onDrop = onDrop }
    deinit { onDrop() }
    func prewarm() async throws { }
    func prepareSession(language: String?) -> MLXPreparedSession {
        MLXPreparedSession(stream: FakeMLXStream()) { _ in "batch" }
    }
}

@MainActor
final class MLXModelIdleUnloadTests: XCTestCase {
    func testIdleUnloadDropsModelBeforeClearingBuffersAndNextRecordingReloads() async throws {
        let dropped = Lock(false)
        let cleared = OneShotChannel<Void>()
        let loads = Lock(0)
        let store = MLXModelStore(clearCache: {
            XCTAssertTrue(dropped.value())
            cleared.finish(())
        }) { _ in
            loads.withLock { $0 += 1 }
            return IdleUnloadModel { dropped.withLock { $0 = true } }
        }
        await store.setIdleUnloadDelay(0.03)
        await store.preload(MLXModelCatalog.defaultModel)
        guard case .signaled = await cleared.wait(timeout: 1) else {
            return XCTFail("Idle timer did not clear the cache")
        }
        let state = await store.state
        XCTAssertEqual(state, .idle)
        let lease = try await store.acquireSessionLease()
        _ = try await store.load(MLXModelCatalog.defaultModel, lease: lease)
        XCTAssertEqual(loads.value(), 2)
        await lease.release()
    }

    func testAcquireCancelsTimerAndDuplicateReleaseCannotUnloadHeldLease() async throws {
        let cleared = OneShotChannel<Void>()
        let store = MLXModelStore(clearCache: { cleared.finish(()) }) { _ in IdleUnloadModel() }
        await store.setIdleUnloadDelay(0.05)
        let first = try await store.acquireSessionLease()
        _ = try await store.load(MLXModelCatalog.defaultModel, lease: first)
        await first.release()
        let second = try await store.acquireSessionLease()
        await first.release()
        if case .signaled = await cleared.wait(timeout: 0.15) {
            XCTFail("Unloaded while the next recording held its lease")
        }
        let state = await store.state
        XCTAssertEqual(state, .ready(repoID: MLXModelCatalog.defaultModel.repoID))
        await second.release()
        guard case .signaled = await cleared.wait(timeout: 1) else {
            return XCTFail("Release did not start a fresh idle period")
        }
    }

    func testChangedDelayAppliesToNextIdlePeriod() async throws {
        let cleared = Lock(0)
        let store = MLXModelStore(clearCache: { cleared.withLock { $0 += 1 } }) { _ in IdleUnloadModel() }
        await store.setIdleUnloadDelay(0.03)
        await store.preload(MLXModelCatalog.defaultModel)
        await store.setIdleUnloadDelay(0.3)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(cleared.value(), 1, "Existing timer keeps its original delay")
        await store.preload(MLXModelCatalog.defaultModel)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(cleared.value(), 1, "New idle period uses the changed delay")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(cleared.value(), 2)
    }

    func testCancelledWaiterRestartsTimerButEvictionWaitsForProcessLease() async throws {
        let cleared = OneShotChannel<Void>()
        let store = MLXModelStore(clearCache: { cleared.finish(()) }) { _ in IdleUnloadModel() }
        await store.setIdleUnloadDelay(0.03)
        await store.preload(MLXModelCatalog.defaultModel)
        let otherLease = try await MLXModelStore().acquireSessionLease()
        let waiting = Task { try await store.acquireSessionLease() }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        do {
            let lease = try await waiting.value
            await lease.release()
            XCTFail("Cancelled waiter acquired a lease")
        } catch is CancellationError { }
        if case .signaled = await cleared.wait(timeout: 0.1) {
            XCTFail("Eviction overlapped another store's lease")
        }
        await otherLease.release()
        guard case .signaled = await cleared.wait(timeout: 1) else {
            return XCTFail("Cancelled acquire left the store permanently busy")
        }
    }

    func testCachedWarmupRestartsIdlePeriod() async throws {
        let cleared = OneShotChannel<Void>()
        let store = MLXModelStore(clearCache: { cleared.finish(()) }) { _ in IdleUnloadModel() }
        await store.setIdleUnloadDelay(0.15)
        await store.preload(MLXModelCatalog.defaultModel)
        try await Task.sleep(for: .milliseconds(100))
        await store.preload(MLXModelCatalog.defaultModel)
        if case .signaled = await cleared.wait(timeout: 0.1) {
            XCTFail("Cached warmup did not cancel the previous timer")
        }
        guard case .signaled = await cleared.wait(timeout: 1) else {
            return XCTFail("Cached warmup did not start a new timer")
        }
    }
}
