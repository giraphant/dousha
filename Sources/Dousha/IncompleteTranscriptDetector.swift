import Foundation
import DoubaoASR

/// Heuristic check for "did the streaming ASR probably miss part of the audio?"
///
/// Three independent signals; OR-combined:
///
/// 1. **Stale last-transcript**: if the server hasn't produced any new
///    non-empty transcript content for >3s before the user released the
///    hotkey, the WebSocket / transcription pipeline likely dropped mid-session
///    and the tail of the audio never got served. We use `lastTranscriptAge`
///    (not `lastResponseAge`) so the signal isn't masked by heartbeats from a
///    server whose ASR pipeline has stalled.
///
/// 2. **Segment-gap**: the largest wall-clock gap between consecutive VAD
///    segment commits exceeds the configured threshold. Doubao normally
///    commits frequently enough that a very large gap can mean it silently
///    dropped a chunk of audio in that window. This catches
///    the case where surviving segments are dense enough that the char/sec
///    rate looks normal even though a large middle portion was lost.
///
/// 3. **Char-per-second floor**: normal human speech rates are bounded below.
///    If transcript length divided by audio seconds is far below the language's
///    expected floor, something is missing.
///
/// All signals are gated on a minimum audio duration (5s) — short recordings
/// are too noisy to judge.
struct IncompleteTranscriptDetector {
    /// Minimum audio length before any signal fires. Short clips are too
    /// noisy (one-word commands, throat-clears, etc.).
    let minAudioDuration: TimeInterval = 5.0

    /// Max acceptable gap between user releasing hotkey and the last non-empty
    /// transcript response. Doubao normally produces text within 1-2s of audio
    /// cessation; >3s strongly suggests the stream stopped flowing well before
    /// the hotkey release.
    let maxLastTranscriptAge: TimeInterval = 3.0

    /// Max acceptable gap between segment commits (or between audio start and
    /// first commit). Loosely intended as "if no segment was finalized for >N
    /// seconds, Doubao probably dropped audio in that window".
    ///
    /// Tuned to 25s because DoubaoASR's interim-rescue logic creates segment
    /// boundaries whenever the server starts a new utterance — those rescues
    /// can be 20+ seconds apart during normal continuous speech, so a stricter
    /// threshold trips false-positive retranscribes constantly. The rate-based
    /// signal (char/sec floor) covers the "real chunk dropped" case better
    /// anyway.
    let maxSegmentGap: TimeInterval = 25.0

    /// Per-language chars-per-second floor. Recordings below this rate get
    /// flagged. Picked conservatively (about 50% of typical conversational
    /// rates) so false positives stay rare.
    func charFloor(forLanguage lang: String) -> Double {
        let normalized = lang.lowercased()
        if normalized == LanguageMenu.autoIdentifier || normalized.hasPrefix("zh") { return 2.0 }
        return 8.0
    }

    struct Decision: Equatable {
        let isIncomplete: Bool
        let staleLastTranscript: Bool
        let largeSegmentGap: Bool
        let belowCharFloor: Bool
        let charsPerSecond: Double
    }

    func decision(for result: TranscriptionResult, language: String) -> Decision {
        let observedRate = result.audioDuration > 0
            ? Double(result.text.count) / result.audioDuration
            : 0

        guard result.audioDuration >= minAudioDuration else {
            return Decision(
                isIncomplete: false,
                staleLastTranscript: false,
                largeSegmentGap: false,
                belowCharFloor: false,
                charsPerSecond: observedRate
            )
        }

        let stale = result.lastTranscriptAge.map { $0 > maxLastTranscriptAge } ?? false
        let largeGap = result.maxSegmentGap.map { $0 > maxSegmentGap } ?? false
        let floor = charFloor(forLanguage: language)
        let belowFloor = observedRate < floor * 0.5

        return Decision(
            isIncomplete: stale || largeGap || belowFloor,
            staleLastTranscript: stale,
            largeSegmentGap: largeGap,
            belowCharFloor: belowFloor,
            charsPerSecond: observedRate
        )
    }

    func isLikelyIncomplete(result: TranscriptionResult, language: String) -> Bool {
        decision(for: result, language: language).isIncomplete
    }
}
