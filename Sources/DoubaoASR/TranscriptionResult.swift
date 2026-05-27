import Foundation

/// What `SpeechBackend.stop()` hands back to the caller. Carries the recognised
/// text plus the timing diagnostics the caller needs to decide whether the
/// stream was probably truncated mid-recording (WebSocket drop, server error).
///
/// We track **two** server-side timestamps and they mean different things:
///
/// - `lastResponseAge`: age of the most recent byte from the server, including
///   heartbeats / keepalives. Mostly useful for debugging "is the WS alive at
///   all" — NOT used by the incomplete-detection heuristic, because a server
///   that's still pinging us but not transcribing would mask a real drop.
///
/// - `lastTranscriptAge`: age of the most recent message that actually carried
///   non-empty transcript content. THIS is the staleness signal the detector
///   uses: a large gap means the server stopped producing text well before
///   the user released the hotkey.
///
/// `audioDuration` and `text.count` together drive the secondary char/sec
/// heuristic.
public struct TranscriptionResult: Sendable {
    public let text: String
    public let audioDuration: TimeInterval
    public let lastResponseAge: TimeInterval?
    public let lastTranscriptAge: TimeInterval?
    /// Path to the WAV that captured this session's mic input, or nil if the
    /// backend doesn't support WAV capture (e.g., Apple backend).
    public let savedAudioURL: URL?

    public init(
        text: String,
        audioDuration: TimeInterval,
        lastResponseAge: TimeInterval?,
        lastTranscriptAge: TimeInterval?,
        savedAudioURL: URL?
    ) {
        self.text = text
        self.audioDuration = audioDuration
        self.lastResponseAge = lastResponseAge
        self.lastTranscriptAge = lastTranscriptAge
        self.savedAudioURL = savedAudioURL
    }
}
