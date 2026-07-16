import XCTest
import ASRSupport

/// QUA-265: deterministic tests for the local VAD-like segment model. All
/// timing is caller-supplied — no live audio, no ASR server, no wall clock.
final class ASRSegmentModelTests: XCTestCase {
    private let config = ASRSegmentModel.Config(pauseBoundary: 1.5, revisionWindow: 3.0)

    // MARK: Partial accumulation

    func testPartialsReplaceActiveHypothesis() {
        var model = ASRSegmentModel(config: config)
        model.observePartial("he", at: 0.0)
        model.observePartial("hello wor", at: 0.5)
        model.observePartial("hello world", at: 1.0)

        XCTAssertEqual(model.activeText, "hello world")
        XCTAssertEqual(model.pendingText, "")
        XCTAssertEqual(model.committedText, "")
        XCTAssertEqual(model.segments.count, 1)
    }

    func testEmptyPartialIsIgnored() {
        var model = ASRSegmentModel(config: config)
        model.observePartial("", at: 0.0)
        XCTAssertTrue(model.segments.isEmpty)
    }

    // MARK: Pause-like boundary

    func testSilenceParksActiveSegmentAsPending() {
        var model = ASRSegmentModel(config: config)
        model.observePartial("first utterance", at: 0.0)
        model.tick(at: 1.5)

        XCTAssertEqual(model.activeText, "")
        XCTAssertEqual(model.pendingText, "first utterance")
    }

    func testRepeatedIdenticalHypothesisDoesNotResetPauseTimer() {
        var model = ASRSegmentModel(config: config)
        model.observePartial("steady", at: 0.0)
        // The engine re-sends the same hypothesis during silence.
        model.observePartial("steady", at: 1.0)
        model.tick(at: 1.6)

        XCTAssertEqual(model.pendingText, "steady")
    }

    func testContinuingHypothesisReactivatesPendingSegment() {
        var model = ASRSegmentModel(config: config)
        model.observePartial("pause here", at: 0.0)
        model.tick(at: 2.0) // parked as pending
        model.observePartial("pause here and resume", at: 2.5)

        XCTAssertEqual(model.activeText, "pause here and resume")
        XCTAssertEqual(model.pendingText, "")
        XCTAssertEqual(model.segments.count, 1)
    }

    func testDramaticShrinkRescuesPreviousAsLocallyFinalized() {
        var model = ASRSegmentModel(config: config)
        model.observePartial("this is a much longer first utterance", at: 0.0)
        model.observePartial("next", at: 0.5)

        // The engine abandoned the first utterance (no final will ever come),
        // so the rescue finalizes it locally rather than leaving it pending.
        XCTAssertEqual(model.recentlyFinalizedText, "this is a much longer first utterance")
        XCTAssertEqual(model.activeText, "next")
        XCTAssertEqual(model.segments.count, 2)
    }

    func testIdenticalHypothesisDoesNotReactivateParkedSegment() {
        var model = ASRSegmentModel(config: config)
        model.observePartial("parked", at: 0.0)
        model.tick(at: 2.0) // parked as pending
        model.observePartial("parked", at: 2.5) // engine re-sends during silence

        XCTAssertEqual(model.pendingText, "parked")
        XCTAssertEqual(model.activeText, "")
    }

    // MARK: Final events

    func testFinalResolvesActiveSegment() {
        var model = ASRSegmentModel(config: config)
        model.observePartial("hello wor", at: 0.0)
        model.observeFinal("hello world.", at: 0.8)

        XCTAssertEqual(model.activeText, "")
        XCTAssertEqual(model.recentlyFinalizedText, "hello world.")
        XCTAssertEqual(model.committedText, "")
    }

    func testRecentlyFinalizedCommitsAfterRevisionWindow() {
        var model = ASRSegmentModel(config: config)
        model.observeFinal("done.", at: 0.0)
        model.tick(at: 3.0)

        XCTAssertEqual(model.recentlyFinalizedText, "")
        XCTAssertEqual(model.committedText, "done.")
    }

    func testFinalAfterShrinkRescueRoutesToTheNewActiveSegment() {
        var model = ASRSegmentModel(config: config)
        model.observePartial("this is a much longer first utterance", at: 0.0)
        model.observePartial("next", at: 0.5) // shrink: first rescued as finalized
        model.observeFinal("next.", at: 1.0)

        XCTAssertEqual(model.recentlyFinalizedText,
                       "this is a much longer first utterance" + "next.")
        XCTAssertEqual(model.activeText, "")
        XCTAssertEqual(model.fullText, "this is a much longer first utterancenext.")
    }

    func testEmptyFinalResolvesPendingWithLocalText() {
        var model = ASRSegmentModel(config: config)
        model.observePartial("kept as heard", at: 0.0)
        model.observeFinal("", at: 1.0) // endpoint marker with no new text

        XCTAssertEqual(model.recentlyFinalizedText, "kept as heard")
    }

    func testFinalWithoutPriorPartialsCreatesFinalizedSegment() {
        var model = ASRSegmentModel(config: config)
        model.observeFinal("out of nowhere.", at: 0.0)

        XCTAssertEqual(model.recentlyFinalizedText, "out of nowhere.")
        XCTAssertEqual(model.segments.count, 1)
    }

    func testEmptyFinalWithNothingUnresolvedIsNoOp() {
        var model = ASRSegmentModel(config: config)
        model.observeFinal("", at: 0.0)
        XCTAssertTrue(model.segments.isEmpty)
    }

    // MARK: Stop flush

    func testStopFlushCommitsEverythingAndReturnsFullTranscript() {
        var model = ASRSegmentModel(config: config)
        model.observeFinal("first. ", at: 0.0)
        model.observePartial("second utterance still going", at: 1.0)
        model.tick(at: 3.0) // first commits (window elapsed); second parks pending
        model.observePartial("third", at: 3.2)

        let flushed = model.flushOnStop(at: 4.0)

        XCTAssertEqual(flushed, "first. " + "second utterance still going" + "third")
        XCTAssertEqual(model.committedText, flushed)
        XCTAssertEqual(model.activeText, "")
        XCTAssertEqual(model.pendingText, "")
        XCTAssertEqual(model.recentlyFinalizedText, "")
    }

    func testStopFlushIsIdempotent() {
        var model = ASRSegmentModel(config: config)
        model.observePartial("only utterance", at: 0.0)
        let first = model.flushOnStop(at: 1.0)
        let second = model.flushOnStop(at: 9.0)

        XCTAssertEqual(first, "only utterance")
        XCTAssertEqual(second, first)
        XCTAssertEqual(model.segments.count, 1)
    }

    // MARK: Late revisions

    func testRevisionReplacesRecentlyFinalizedText() {
        var model = ASRSegmentModel(config: config)
        model.observePartial("forty for", at: 0.0)
        model.observeFinal("forty four", at: 1.0)
        let accepted = model.observeRevision("44", at: 2.0)

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.recentlyFinalizedText, "44")
    }

    func testRevisionRejectedAfterCommitWindow() {
        var model = ASRSegmentModel(config: config)
        model.observeFinal("locked in.", at: 0.0)
        let accepted = model.observeRevision("rewritten.", at: 3.5) // window elapsed → committed

        XCTAssertFalse(accepted)
        XCTAssertEqual(model.committedText, "locked in.")
    }

    func testRevisionNeverTouchesCommittedSegments() {
        var model = ASRSegmentModel(config: config)
        model.observeFinal("old and committed. ", at: 0.0)
        model.observeFinal("fresh.", at: 4.0) // first commits at t=3.0 via lazy tick
        let accepted = model.observeRevision("revised fresh.", at: 4.5)

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.committedText, "old and committed. ")
        XCTAssertEqual(model.recentlyFinalizedText, "revised fresh.")
    }

    func testRevisionCannotExtendItsOwnWindow() {
        var model = ASRSegmentModel(config: config)
        model.observeFinal("first pass", at: 0.0)
        model.observeRevision("second pass", at: 2.9)
        model.tick(at: 3.0) // window anchored at the original final, not the revision

        XCTAssertEqual(model.committedText, "second pass")
        XCTAssertFalse(model.observeRevision("third pass", at: 3.1))
    }

    // MARK: Determinism

    func testReplayingTheSameEventTimelineYieldsIdenticalState() {
        func run() -> ASRSegmentModel {
            var model = ASRSegmentModel(config: config)
            model.observePartial("alpha", at: 0.0)
            model.tick(at: 2.0)
            model.observePartial("alpha beta", at: 2.2)
            model.observeFinal("alpha beta.", at: 3.0)
            model.observeRevision("alpha beta!", at: 4.0)
            model.observePartial("gamma", at: 5.0)
            model.flushOnStop(at: 6.0)
            return model
        }
        XCTAssertEqual(run(), run())
    }
}
