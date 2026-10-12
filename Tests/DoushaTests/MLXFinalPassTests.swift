import XCTest
import Foundation
import ASRSupport
import ConcurrencySupport
import MLXAudioSTT
@testable import MLXASR

private final class FakeMLXStream: MLXStreamingSession {
    let events: AsyncStream<TranscriptionEvent>
    let continuation: AsyncStream<TranscriptionEvent>.Continuation
    let stopped = OneShotChannel<Void>()
    let cancelled = Lock(false)
    let endOnStop: Bool
    let text: String

    init(text: String = "preview", endOnStop: Bool = true) {
        (events, continuation) = AsyncStream.makeStream()
        self.text = text
        self.endOnStop = endOnStop
    }
    func feedAudio(samples: [Float]) {
        continuation.yield(.displayUpdate(confirmedText: "", provisionalText: text))
    }
    func stop() {
        stopped.finish(())
        if endOnStop { end() }
    }
    func end() {
        continuation.yield(.ended(fullText: text))
        continuation.finish()
    }
    func cancel() {
        cancelled.withLock { $0 = true }
        continuation.finish()
    }
}

@MainActor
final class MLXFinalPassTests: XCTestCase {
    private func prepare(_ engine: MLXStreamingASR, context: String = "", language: String = "auto") async {
        await engine.prepareSession(onPartial: { _ in }, onError: { _ in XCTFail("Unexpected engine error") },
                                    language: language, context: context)
        engine.ingest(Data([0x00, 0x40, 0x00]))
        engine.ingest(Data([0x80]))
        engine.openStream()
    }

    private func stop(_ engine: MLXStreamingASR) -> OneShotChannel<TranscriptionResult> {
        let result = OneShotChannel<TranscriptionResult>(TranscriptionResult.self)
        engine.stop {
            XCTAssertTrue(Thread.isMainThread)
            result.finish($0)
        }
        return result
    }

    func testBatchWinsAfterStreamingCleanupAndReceivesFullPCMContextAndLanguage() async throws {
        let stream = FakeMLXStream()
        let request = Lock<MLXFinalPassRequest?>(nil)
        let engine = MLXStreamingASR { _, _, _, language in
            XCTAssertEqual(language, "Chinese")
            return MLXPreparedSession(stream: stream) { value in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertTrue(stream.cancelled.value(), "Streaming cleanup must precede batch inference")
                request.withLock { $0 = value }
                return "language Chinese<asr_text>批量结果"
            }
        }
        await prepare(engine, context: "Vocabulary:\n- Dousha", language: "zh-CN")
        let result = try await stop(engine).wait()
        XCTAssertEqual(result.text, "批量结果")
        XCTAssertEqual(request.value()?.pcm, Data([0x00, 0x40, 0x00, 0x80]))
        XCTAssertEqual(request.value()?.context, "Vocabulary:\n- Dousha")
        XCTAssertEqual(request.value()?.language, "Chinese")
        let metrics = await engine.finalPassMetrics
        XCTAssertEqual(metrics?.source, "batch")
        XCTAssertEqual(metrics?.audioSeconds, 2 / 16_000)
    }

    func testEmptyOrMetadataOnlyBatchFallsBackToGuardedStream() async throws {
        for batch in ["", " \n ", "language English<asr_text>"] {
            let stream = FakeMLXStream(text: String(repeating: "我，", count: 38))
            let engine = MLXStreamingASR { _, _, _, _ in
                MLXPreparedSession(stream: stream) { _ in batch }
            }
            await prepare(engine)
            let result = try await stop(engine).wait()
            XCTAssertEqual(result.text, String(repeating: "我，", count: 4))
            let metrics = await engine.finalPassMetrics
            XCTAssertEqual(metrics?.source, "stream")
        }
    }

    func testThrowingBatchFallsBack() async throws {
        let stream = FakeMLXStream()
        let engine = MLXStreamingASR { _, _, _, _ in
            MLXPreparedSession(stream: stream) { _ in throw CancellationError() }
        }
        await prepare(engine)
        let result = try await stop(engine).wait()
        XCTAssertEqual(result.text, "preview")
    }

    func testAutoBatchHeadersAreFilteredWithoutApplyingThePreviewRepetitionGuard() async throws {
        let batch = String(repeating: "很多", count: 6)
        let engine = MLXStreamingASR { _, _, _, language in
            XCTAssertNil(language)
            return MLXPreparedSession(stream: FakeMLXStream()) { request in
                XCTAssertNil(request.language)
                return "language Chinese<asr_text>" + batch
            }
        }
        await prepare(engine)
        let result = try await stop(engine).wait()
        XCTAssertEqual(result.text, batch)
    }

    func testDisabledFinalPassNeverInvokesRunner() async throws {
        let stream = FakeMLXStream()
        let engine = MLXStreamingASR(finalPass: false) { _, _, _, _ in
            MLXPreparedSession(stream: stream) { _ in
                XCTFail("Disabled final pass ran")
                return "batch"
            }
        }
        await prepare(engine)
        let result = try await stop(engine).wait()
        XCTAssertEqual(result.text, "preview")
        let metrics = await engine.finalPassMetrics
        XCTAssertEqual(metrics?.source, "stream")
        XCTAssertEqual(metrics?.batchMilliseconds, 0)
    }

    func testDeadlineDeliversOnceDiscardsLateResultAndHoldsLeaseUntilRunnerReturns() async throws {
        let stream = FakeMLXStream()
        let started = OneShotChannel<Void>()
        let releaseBatch = OneShotChannel<Void>()
        let engine = MLXStreamingASR(finalPassTimeout: 0.03) { _, _, _, _ in
            MLXPreparedSession(stream: stream) { _ in
                started.finish(())
                try await releaseBatch.wait()
                return "late batch"
            }
        }
        await prepare(engine)
        let completed = expectation(description: "one fallback completion")
        let count = Lock(0)
        engine.stop { result in
            XCTAssertEqual(result.text, "preview")
            count.withLock { $0 += 1 }
            completed.fulfill()
        }
        engine.stop { _ in XCTFail("Duplicate stop emitted a completion") }
        _ = try await started.wait()
        await fulfillment(of: [completed], timeout: 1)
        let store = MLXModelStore()
        let acquired = OneShotChannel<MLXSessionLease>(MLXSessionLease.self)
        let waiter = Task { acquired.finish(try await store.acquireSessionLease()) }
        if case .signaled = await acquired.wait(timeout: 0.03) { XCTFail("Deadline released the active batch lease") }
        releaseBatch.finish(())
        let lease = try await acquired.wait()
        await lease.release()
        _ = await waiter.result
        XCTAssertEqual(count.value(), 1)
        let metrics = await engine.finalPassMetrics
        XCTAssertEqual(metrics?.source, "stream", "Late batch must not rewrite delivery metrics")
    }

    func testCancelDuringFinalPassSuppressesCompletionAndRetainsLease() async throws {
        let stream = FakeMLXStream()
        let started = OneShotChannel<Void>()
        let releaseBatch = OneShotChannel<Void>()
        let engine = MLXStreamingASR { _, _, _, _ in
            MLXPreparedSession(stream: stream) { _ in
                started.finish(())
                try await releaseBatch.wait()
                return "cancelled batch"
            }
        }
        await prepare(engine)
        let unexpected = expectation(description: "cancelled final emits no completion")
        unexpected.isInverted = true
        engine.stop { _ in unexpected.fulfill() }
        _ = try await started.wait()
        engine.cancel()
        let store = MLXModelStore()
        let acquired = OneShotChannel<MLXSessionLease>(MLXSessionLease.self)
        let waiter = Task { acquired.finish(try await store.acquireSessionLease()) }
        if case .signaled = await acquired.wait(timeout: 0.03) { XCTFail("Cancel released the active batch lease") }
        releaseBatch.finish(())
        let lease = try await acquired.wait()
        await lease.release()
        _ = await waiter.result
        await fulfillment(of: [unexpected], timeout: 0.05)
    }

    func testStreamingTimeoutNeverStartsConcurrentBatchAndRetainsLeaseUntilNaturalEnd() async throws {
        let stream = FakeMLXStream(endOnStop: false)
        let engine = MLXStreamingASR(finalPassTimeout: 0.03, streamEndTimeout: 0.03, streamCleanupTimeout: 0.03) { _, _, _, _ in
            MLXPreparedSession(stream: stream) { _ in
                XCTFail("An abandoned final pass must not start late")
                return "batch"
            }
        }
        await prepare(engine)
        let result = try await stop(engine).wait()
        XCTAssertEqual(result.text, "preview")
        XCTAssertFalse(stream.cancelled.value(), "cancel() is not a native decoder barrier")
        let store = MLXModelStore()
        let acquired = OneShotChannel<MLXSessionLease>(MLXSessionLease.self)
        let waiter = Task { acquired.finish(try await store.acquireSessionLease()) }
        if case .signaled = await acquired.wait(timeout: 0.03) { XCTFail("Streaming decoder still owns the lease") }
        stream.end()
        let lease = try await acquired.wait()
        await lease.release()
        _ = await waiter.result
        XCTAssertTrue(stream.cancelled.value())
    }

    func testLateNaturalEndWithinCleanupAllowanceStillRunsBatchAfterCleanup() async throws {
        let stream = FakeMLXStream(endOnStop: false)
        let engine = MLXStreamingASR(streamEndTimeout: 0.01, streamCleanupTimeout: 1) { _, _, _, _ in
            MLXPreparedSession(stream: stream) { _ in
                XCTAssertTrue(stream.cancelled.value())
                return "batch after late end"
            }
        }
        await prepare(engine)
        let result = stop(engine)
        _ = try await stream.stopped.wait()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(stream.cancelled.value())
        stream.end()
        let final = try await result.wait()
        XCTAssertEqual(final.text, "batch after late end")
    }

    func testRestartWhileBatchIsRunningCannotReceiveOldResult() async throws {
        let started = OneShotChannel<Void>()
        let releaseBatch = OneShotChannel<Void>()
        let attempts = Lock(0)
        let engine = MLXStreamingASR { _, _, _, _ in
            let first = attempts.withLock { $0 += 1; return $0 == 1 }
            return MLXPreparedSession(stream: FakeMLXStream()) { _ in
                if first {
                    started.finish(())
                    try await releaseBatch.wait()
                    return "old batch"
                }
                return "new batch"
            }
        }
        await prepare(engine)
        let unexpected = expectation(description: "old result is quarantined")
        unexpected.isInverted = true
        engine.stop { _ in unexpected.fulfill() }
        _ = try await started.wait()
        await prepare(engine)
        let newResult = stop(engine)
        releaseBatch.finish(())
        let result = try await newResult.wait()
        XCTAssertEqual(result.text, "new batch")
        await fulfillment(of: [unexpected], timeout: 0.05)
    }
}
