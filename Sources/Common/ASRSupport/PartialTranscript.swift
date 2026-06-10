import Foundation

/// A live transcript snapshot split into the finalized prefix and the
/// not-yet-final interim tail, so the HUD can render the two with different
/// emphasis. Both fields are cumulative (the whole transcript so far), not
/// deltas. `interimText` is empty once the utterance is finalized.
public struct PartialTranscript: Sendable, Equatable {
    public let finalText: String
    public let interimText: String

    public init(finalText: String, interimText: String) {
        self.finalText = finalText
        self.interimText = interimText
    }

    /// Finalized prefix followed by the interim tail — the full live text.
    public var combined: String { finalText + interimText }

    public static let empty = PartialTranscript(finalText: "", interimText: "")
}
