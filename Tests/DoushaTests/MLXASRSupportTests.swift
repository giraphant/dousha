import XCTest
import Foundation
import ASRSupport
import ConcurrencySupport
import MLXAudioSTT
@testable import MLXASR

final class MLXASRSupportTests: XCTestCase {
    func testPCMExtremesAndZero() {
        let pcm = Data([0x00, 0x80, 0xff, 0x7f, 0x00, 0x00, 0xff, 0xff])
        XCTAssertEqual(MLXASRSupport.floatSamples(fromPCM16LE: pcm), [-1, 32_767 / 32_768, 0, -1 / 32_768])
    }

    func testPCMUsesLittleEndianAndSignedSamples() {
        let pcm = Data([0x34, 0x12, 0xcc, 0xed, 0x00, 0x40, 0x00, 0xc0])
        XCTAssertEqual(MLXASRSupport.floatSamples(fromPCM16LE: pcm), [4_660 / 32_768, -4_660 / 32_768, 0.5, -0.5])
    }

    func testPCMIgnoresOddTrailingByte() {
        XCTAssertEqual(MLXASRSupport.floatSamples(fromPCM16LE: Data([0x00, 0x40, 0xff])), [0.5])
        XCTAssertEqual(MLXASRSupport.floatSamples(fromPCM16LE: Data([0xff])), [])
        XCTAssertEqual(MLXASRSupport.floatSamples(fromPCM16LE: Data()), [])
    }

    func testPCMHandlesSlicedDataWithoutAlignmentAssumptions() {
        let storage = Data([0xff, 0x00, 0x80, 0xff, 0x7f])
        XCTAssertEqual(MLXASRSupport.floatSamples(fromPCM16LE: storage.dropFirst()), [-1, 32_767 / 32_768])
    }

    func testLanguagePrefixes() {
        for identifier in ["zh", "zh-CN", "zh-TW", "zh_Hans", "ZH-hk"] {
            XCTAssertEqual(MLXASRSupport.qwenLanguage(forIdentifier: identifier), "Chinese")
        }
        for identifier in ["en", "en-US", "en-GB", "EN_au"] {
            XCTAssertEqual(MLXASRSupport.qwenLanguage(forIdentifier: identifier), "English")
        }
    }

    func testOtherLanguagesAndAutoAreExplicitlyUnspecified() {
        for identifier in ["auto", "AUTO", "", "ja-JP", "fr", "de-DE"] {
            XCTAssertNil(MLXASRSupport.qwenLanguage(forIdentifier: identifier))
        }
    }

    func testDisplayUpdatesReplaceTheCumulativeSnapshot() {
        var state = MLXTranscriptState()
        XCTAssertEqual(state.consume(.displayUpdate(confirmedText: "Hello ", provisionalText: "world")),
                       PartialTranscript(finalText: "Hello", interimText: " world"))
        XCTAssertEqual(state.finalText(endedText: nil), "Hello world")
        XCTAssertNil(state.consume(.confirmed(text: "Hello world")))
        XCTAssertNil(state.consume(.provisional(text: "world!")))
        XCTAssertEqual(state.finalText(endedText: nil), "Hello world")
        _ = state.consume(.displayUpdate(confirmedText: "Hello world!", provisionalText: ""))
        XCTAssertEqual(state.finalText(endedText: nil), "Hello world!")
    }

    func testFinalIsAuthoritativeIncludingEmptyText() {
        var state = MLXTranscriptState()
        XCTAssertEqual(state.finalText(endedText: nil), "")
        _ = state.consume(.displayUpdate(confirmedText: "你", provisionalText: "好"))
        XCTAssertEqual(state.finalText(endedText: nil), "你好")
        XCTAssertEqual(state.finalText(endedText: "您好。"), "您好。")
        XCTAssertEqual(state.finalText(endedText: ""), "")
    }

    func testInputBuffersEarlyAudioAndPreservesSplitSamples() {
        let input = MLXSessionInput()
        input.append(Data([0xff, 0xff])) // Before prepare: dropped.
        let generation = input.prepare()
        input.append(Data([0x00]))
        XCTAssertEqual(input.drain(generation), Data())
        input.append(Data([0x40, 0x00, 0x80, 0xff]))
        XCTAssertEqual(input.drain(generation), Data([0x00, 0x40, 0x00, 0x80]))
        input.append(Data([0x7f]))
        XCTAssertEqual(input.drain(generation), Data([0xff, 0x7f]))
        XCTAssertEqual(input.drain(generation), Data())
    }

    func testStopRetainsTailForFinalDrainAndDropsLateIngest() {
        let input = MLXSessionInput()
        let generation = input.prepare()
        input.append(Data([0x00, 0x40]))
        input.stopAccepting(generation)
        input.append(Data([0x00, 0x80]))
        XCTAssertEqual(input.drain(generation), Data())
        XCTAssertEqual(input.drain(generation, final: true), Data([0x00, 0x40]))
        XCTAssertEqual(input.drain(generation, final: true), Data())
    }

    func testStaleOperationsCannotDrainOrCancelNewGeneration() {
        let input = MLXSessionInput()
        let old = input.prepare()
        input.append(Data([0xff, 0xff]))
        let current = input.prepare()
        input.append(Data([0x00, 0x40]))
        input.cancel(old)
        input.stopAccepting(old)
        XCTAssertFalse(input.permitsCallback(old))
        XCTAssertFalse(input.claimCompletion(old))
        XCTAssertEqual(input.drain(old, final: true), Data())
        XCTAssertEqual(input.drain(current), Data([0x00, 0x40]))
        XCTAssertTrue(input.permitsCallback(current))
    }

    func testCompletionCanOnlyBeClaimedOnceAndDisablesCallbacks() {
        let input = MLXSessionInput()
        let generation = input.prepare()
        XCTAssertTrue(input.claimCompletion(generation))
        XCTAssertFalse(input.claimCompletion(generation))
        XCTAssertFalse(input.permitsCallback(generation))
        input.append(Data([0x00, 0x40]))
        XCTAssertEqual(input.drain(generation, final: true), Data())
    }

    func testCancelDiscardsAudioAndSuppressesCompletion() {
        let input = MLXSessionInput()
        let generation = input.prepare()
        input.append(Data([0x00, 0x40]))
        input.cancel(generation)
        input.cancel(generation)
        XCTAssertEqual(input.drain(generation, final: true), Data())
        XCTAssertFalse(input.claimCompletion(generation))
        XCTAssertFalse(input.permitsCallback(generation))
    }
}

@MainActor
final class MLXASRLeaseTests: XCTestCase {
    func testExclusiveLeaseAndIdempotentRelease() async throws {
        let gate = MLXSessionLeaseGate()
        let first = try await gate.acquire()
        let acquired = OneShotChannel<MLXSessionLease>(MLXSessionLease.self)
        let waiter = Task {
            let second = try await gate.acquire()
            acquired.finish(second)
            return second
        }
        if case .signaled = await acquired.wait(timeout: 0.02) {
            XCTFail("Second session acquired while first still owns the lease")
        }
        await first.release()
        let second = try await waiter.value
        await first.release() // Must not release the new owner.

        let thirdAcquired = OneShotChannel<MLXSessionLease>(MLXSessionLease.self)
        let thirdWaiter = Task {
            let third = try await gate.acquire()
            thirdAcquired.finish(third)
            return third
        }
        if case .signaled = await thirdAcquired.wait(timeout: 0.02) {
            XCTFail("Duplicate release advanced another session's lease")
        }
        await second.release()
        let third = try await thirdWaiter.value
        await third.release()
    }

    func testCancelledWaiterDoesNotConsumeNextLease() async throws {
        let gate = MLXSessionLeaseGate()
        let first = try await gate.acquire()
        let waiting = OneShotChannel<Void>()
        let cancelledWaiter = Task {
            waiting.finish(())
            return try await gate.acquire()
        }
        _ = await waiting.wait(timeout: 1)
        cancelledWaiter.cancel()
        do {
            let lease = try await cancelledWaiter.value
            await lease.release()
            XCTFail("Cancelled acquire should throw")
        } catch is CancellationError {
            // Expected; the gate must remove this waiter.
        }
        await first.release()
        let next = try await gate.acquire()
        await next.release()
    }

    func testSeparatelyConstructedStoresShareTheProcessLease() async throws {
        let firstStore = MLXModelStore()
        let secondStore = MLXModelStore()
        let first = try await firstStore.acquireSessionLease()
        let acquired = OneShotChannel<MLXSessionLease>(MLXSessionLease.self)
        let waiter = Task {
            let second = try await secondStore.acquireSessionLease()
            acquired.finish(second)
            return second
        }
        if case .signaled = await acquired.wait(timeout: 0.02) {
            XCTFail("Separate stores must still serialize sessions")
        }
        await first.release()
        let second = try await waiter.value
        await second.release()
        let state = await firstStore.state
        XCTAssertEqual(state, .idle, "Lease tests must never load weights")
    }
}
