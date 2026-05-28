import XCTest
import DoubaoASR
@testable import Dousha

final class IncompleteTranscriptDetectorTests: XCTestCase {
    private let det = IncompleteTranscriptDetector()

    private func r(
        text: String,
        audioDuration: TimeInterval,
        lastTranscriptAge: TimeInterval? = nil,
        lastResponseAge: TimeInterval? = nil,
        maxSegmentGap: TimeInterval? = nil
    ) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            audioDuration: audioDuration,
            lastResponseAge: lastResponseAge,
            lastTranscriptAge: lastTranscriptAge,
            maxSegmentGap: maxSegmentGap,
            savedAudioURL: nil
        )
    }

    // MARK: - Short recordings are exempt

    func test_shortRecording_belowMinDuration_neverFlagged() {
        let result = r(text: "嗯", audioDuration: 2.0, lastTranscriptAge: 10.0)
        XCTAssertFalse(det.isLikelyIncomplete(result: result, language: "zh-CN"))
    }

    // MARK: - Stale-last-transcript signal (the strong WS-drop indicator)

    func test_staleLastTranscript_chineseRecording_flagged() {
        // 30s recording, but server stopped producing text 20s ago → WS dropped
        let result = r(text: "你好世界你好世界你好世界", audioDuration: 30.0, lastTranscriptAge: 20.0)
        XCTAssertTrue(det.isLikelyIncomplete(result: result, language: "zh-CN"))
    }

    func test_freshLastTranscript_decentRatio_notFlagged() {
        let result = r(text: String(repeating: "字", count: 90), audioDuration: 30.0, lastTranscriptAge: 0.5)
        XCTAssertFalse(det.isLikelyIncomplete(result: result, language: "zh-CN"))
    }

    /// Heartbeat-mask defense: server keeps pinging (lastResponseAge fresh)
    /// but transcription pipeline has stalled (lastTranscriptAge old). The
    /// detector must still fire because the transcript signal is stale.
    func test_freshHeartbeatsButStaleTranscript_flagged() {
        let result = r(
            text: "你好世界",
            audioDuration: 30.0,
            lastTranscriptAge: 20.0,   // transcript pipeline stalled
            lastResponseAge: 0.2       // but heartbeats still arriving
        )
        XCTAssertTrue(det.isLikelyIncomplete(result: result, language: "zh-CN"))
    }

    // MARK: - Char-per-second floor signal

    func test_chinese_belowFloor_flagged() {
        // 30s recording, only 10 chars → 0.33 chars/sec, way below 2.0 floor
        let result = r(text: String(repeating: "字", count: 10), audioDuration: 30.0, lastTranscriptAge: 0.5)
        XCTAssertTrue(det.isLikelyIncomplete(result: result, language: "zh-CN"))
    }

    func test_english_belowFloor_flagged() {
        // 30s recording, only 50 chars → ~1.7 chars/sec, below 8.0 floor
        let result = r(text: String(repeating: "a", count: 50), audioDuration: 30.0, lastTranscriptAge: 0.5)
        XCTAssertTrue(det.isLikelyIncomplete(result: result, language: "en-US"))
    }

    func test_english_aboveFloor_notFlagged() {
        // 30s recording, 300 chars (~10 chars/sec, normal)
        let result = r(text: String(repeating: "a", count: 300), audioDuration: 30.0, lastTranscriptAge: 0.5)
        XCTAssertFalse(det.isLikelyIncomplete(result: result, language: "en-US"))
    }

    // MARK: - Missing diagnostics

    func test_noLastTranscriptAge_fallsBackToRatioOnly() {
        let result = r(text: String(repeating: "字", count: 90), audioDuration: 30.0, lastTranscriptAge: nil)
        XCTAssertFalse(det.isLikelyIncomplete(result: result, language: "zh-CN"))
    }

    func test_zeroAudioDuration_neverFlagged() {
        // Avoid division by zero / nonsense flags for instant stop().
        let result = r(text: "", audioDuration: 0, lastTranscriptAge: nil)
        XCTAssertFalse(det.isLikelyIncomplete(result: result, language: "zh-CN"))
    }

    // MARK: - Segment-gap signal

    /// Real-world case from production logs: 68s recording, 146 chars (above floor),
    /// but Doubao dropped a chunk in the middle. lastTranscriptAge looks fine because
    /// the trailing segment came in just before stop. ONLY the gap signal can catch this.
    func test_largeMidGap_flaggedEvenWhenRateIsNormal() {
        let result = r(
            text: String(repeating: "字", count: 146),
            audioDuration: 68.0,
            lastTranscriptAge: 0.5,
            maxSegmentGap: 28.0   // 28s without a segment commit
        )
        XCTAssertTrue(det.isLikelyIncomplete(result: result, language: "zh-CN"))
    }

    func test_normalSegmentGaps_notFlagged() {
        // Healthy VAD-segmented recording: gaps stay well under threshold.
        let result = r(
            text: String(repeating: "字", count: 80),
            audioDuration: 30.0,
            lastTranscriptAge: 0.5,
            maxSegmentGap: 4.5
        )
        XCTAssertFalse(det.isLikelyIncomplete(result: result, language: "zh-CN"))
    }

    /// Boundary: exactly at the threshold should not fire (we use strict > not >=).
    func test_segmentGapAtThreshold_notFlagged() {
        let result = r(
            text: String(repeating: "字", count: 80),
            audioDuration: 30.0,
            lastTranscriptAge: 0.5,
            maxSegmentGap: 25.0
        )
        XCTAssertFalse(det.isLikelyIncomplete(result: result, language: "zh-CN"))
    }
}
