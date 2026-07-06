import XCTest
@testable import Dousha

final class RecordingAudioControlsTests: XCTestCase {
    func testPauseMediaWhenPlaying_pausesOnBeginAndResumesOnEnd() {
        let spy = MediaControlSpy(states: [true])
        let controls = makeControls(spy: spy)

        controls.begin()
        controls.end()

        XCTAssertEqual(spy.probeCalls, 1)
        XCTAssertEqual(spy.mediaKeyCalls, 2)
    }

    func testPauseMediaWhenNothingPlaying_doesNotSendMediaKey() {
        let spy = MediaControlSpy(states: [false])
        let controls = makeControls(spy: spy)

        controls.begin()
        controls.end()

        XCTAssertEqual(spy.probeCalls, 1)
        XCTAssertEqual(spy.mediaKeyCalls, 0)
    }

    func testPauseMediaWhenPlaybackStateUnknown_doesNotSendMediaKey() {
        let spy = MediaControlSpy(states: [nil])
        let controls = makeControls(spy: spy)

        controls.begin()
        controls.end()

        XCTAssertEqual(spy.probeCalls, 1)
        XCTAssertEqual(spy.mediaKeyCalls, 0)
    }

    func testPauseMediaDisabled_doesNotProbeOrSendMediaKey() {
        let spy = MediaControlSpy(states: [true])
        let controls = makeControls(spy: spy, pauseMedia: false)

        controls.begin()
        controls.end()

        XCTAssertEqual(spy.probeCalls, 0)
        XCTAssertEqual(spy.mediaKeyCalls, 0)
    }

    func testDoubleBegin_pausesOnlyOnce() {
        let spy = MediaControlSpy(states: [true, true])
        let controls = makeControls(spy: spy)

        controls.begin()
        controls.begin()

        XCTAssertEqual(spy.probeCalls, 1)
        XCTAssertEqual(spy.mediaKeyCalls, 1)
    }

    func testEndWithoutBegin_isNoOp() {
        let spy = MediaControlSpy(states: [true])
        let controls = makeControls(spy: spy)

        controls.end()

        XCTAssertEqual(spy.probeCalls, 0)
        XCTAssertEqual(spy.mediaKeyCalls, 0)
    }

    func testDoubleEnd_resumesOnlyOnce() {
        let spy = MediaControlSpy(states: [true])
        let controls = makeControls(spy: spy)

        controls.begin()
        controls.end()
        controls.end()

        XCTAssertEqual(spy.probeCalls, 1)
        XCTAssertEqual(spy.mediaKeyCalls, 2)
    }

    func testRecordingCycles_doNotLeakMediaPauseState() {
        let spy = MediaControlSpy(states: [true, false])
        let controls = makeControls(spy: spy)

        controls.begin()
        controls.end()
        controls.begin()
        controls.end()

        XCTAssertEqual(spy.probeCalls, 2)
        XCTAssertEqual(spy.mediaKeyCalls, 2)
    }

    func testFailedPauseDoesNotCreateResumeObligation() {
        let spy = MediaControlSpy(states: [true], sendResult: false)
        let controls = makeControls(spy: spy)

        controls.begin()
        controls.end()

        XCTAssertEqual(spy.probeCalls, 1)
        XCTAssertEqual(spy.mediaKeyCalls, 1)
    }

    private func makeControls(spy: MediaControlSpy,
                              pauseMedia: Bool = true) -> RecordingAudioControls {
        RecordingAudioControls(
            muteSystemAudio: false,
            pauseMedia: pauseMedia,
            mediaPlaybackState: { spy.nextState() },
            mediaKeySender: { spy.sendMediaKey() }
        )
    }
}

private final class MediaControlSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Bool?]
    private let sendResult: Bool
    private(set) var probeCalls = 0
    private(set) var mediaKeyCalls = 0

    init(states: [Bool?], sendResult: Bool = true) {
        self.states = states
        self.sendResult = sendResult
    }

    func nextState() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        probeCalls += 1
        if states.isEmpty { return nil }
        return states.removeFirst()
    }

    func sendMediaKey() -> Bool {
        lock.lock()
        mediaKeyCalls += 1
        let result = sendResult
        lock.unlock()
        return result
    }
}
