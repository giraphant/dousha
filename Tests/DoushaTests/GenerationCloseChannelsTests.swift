import XCTest
import TalkerCommonSync

final class GenerationCloseChannelsTests: XCTestCase {
    // The QUA-130 cross-wakeup: a stale socket's failure callback must wake only
    // its own generation's close waiter, never a newer close that has since
    // overwritten the shared channel.
    func test_signalWakesOnlyMatchingGeneration() {
        var gen = SessionGeneration()
        let g1 = gen.bump()
        let g2 = gen.bump()
        var channels = GenerationCloseChannels()
        let older = channels.register(g1)
        let newer = channels.register(g2)

        channels.signal(g1) // stale socket from generation 1 reports failure

        XCTAssertTrue(older.isFinished, "generation 1's own waiter should be woken")
        XCTAssertFalse(newer.isFinished, "generation 2's waiter must not be woken by generation 1")
    }

    func test_signalUnknownGenerationIsNoop() {
        var gen = SessionGeneration()
        let registered = gen.bump()
        let unknown = gen.bump()
        var channels = GenerationCloseChannels()
        let ch = channels.register(registered)
        channels.signal(unknown)
        XCTAssertFalse(ch.isFinished)
    }

    func test_removeDropsChannelSoLaterSignalIsNoop() {
        var gen = SessionGeneration()
        let g = gen.bump()
        var channels = GenerationCloseChannels()
        let ch = channels.register(g)
        channels.remove(g)
        channels.signal(g)
        XCTAssertFalse(ch.isFinished, "a signal after remove must not finish the dropped channel")
    }
}
