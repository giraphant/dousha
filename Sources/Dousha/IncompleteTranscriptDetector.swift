import Foundation
import DoubaoASR

/// Heuristic check for "did the streaming ASR probably miss part of the audio?"
///
/// Two independent signals; OR-combined:
///
/// 1. **Stale last-transcript**: if the server hasn't produced any new
///    non-empty transcript content for >3s before the user released the
///    hotkey, the WebSocket / transcription pipeline likely dropped mid-session
///    and the tail of the audio never got served. We use `lastTranscriptAge`
///    (not `lastResponseAge`) so the signal isn't masked by heartbeats from a
///    server whose ASR pipeline has stalled.
///
/// 2. **Char-per-second floor**: normal human speech rates are bounded below.
///    If transcript length divided by audio seconds is far below the language's
///    expected floor, something is missing.
///
/// Both signals are gated on a minimum audio duration (5s) — short recordings
/// are too noisy to judge.
struct IncompleteTranscriptDetector {
    /// Minimum audio length before either signal fires. Short clips are too
    /// noisy (one-word commands, throat-clears, etc.).
    let minAudioDuration: TimeInterval = 5.0

    /// Max acceptable gap between user releasing hotkey and the last non-empty
    /// transcript response. Doubao normally produces text within 1-2s of audio
    /// cessation; >3s strongly suggests the stream stopped flowing well before
    /// the hotkey release.
    let maxLastTranscriptAge: TimeInterval = 3.0

    /// Per-language chars-per-second floor. Recordings below this rate get
    /// flagged. Picked conservatively (about 50% of typical conversational
    /// rates) so false positives stay rare.
    func charFloor(forLanguage lang: String) -> Double {
        if lang.lowercased().hasPrefix("zh") { return 2.0 }       // Chinese 字/秒
        return 8.0                                                 // English/Latin chars/秒
    }

    func isLikelyIncomplete(result: TranscriptionResult, language: String) -> Bool {
        guard result.audioDuration >= minAudioDuration else { return false }

        if let age = result.lastTranscriptAge, age > maxLastTranscriptAge {
            return true
        }

        let floor = charFloor(forLanguage: language)
        let observedRate = Double(result.text.count) / result.audioDuration
        if observedRate < floor * 0.5 {
            return true
        }

        return false
    }
}
