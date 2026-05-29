import XCTest
import TalkerCommonSync

final class GenerationCloseChannelsTests: XCTestCase {
    // The QUA-130 cross-wakeup: a stale socket's failure callback must wake only
    // its own generation's close waiter, never a newer close that has since
    // overwritten the shared channel.
    func test_signalWakesOnlyMatchingGeneration() {
        var channels = GenerationCloseChannels()
        let older = channels.register(1)
        let newer = channels.register(2)

        channels.signal(1) // stale socket from generation 1 reports failure

        XCTAssertTrue(older.isFinished, "generation 1's own waiter should be woken")
        XCTAssertFalse(newer.isFinished, "generation 2's waiter must not be woken by generation 1")
    }

    func test_signalUnknownGenerationIsNoop() {
        var channels = GenerationCloseChannels()
        let ch = channels.register(5)
        channels.signal(99)
        XCTAssertFalse(ch.isFinished)
    }

    func test_removeDropsChannelSoLaterSignalIsNoop() {
        var channels = GenerationCloseChannels()
        let ch = channels.register(7)
        channels.remove(7)
        channels.signal(7)
        XCTAssertFalse(ch.isFinished, "a signal after remove must not finish the dropped channel")
    }
}
