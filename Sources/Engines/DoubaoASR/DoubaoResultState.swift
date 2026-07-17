import Foundation
import ASRSupport

/// Pure, `Sendable`, unit-testable state for Doubao streaming results.
///
/// Doubao sends cumulative text for the current VAD-bounded utterance, not for
/// the whole recording. Finalized utterances are therefore accumulated while
/// each new interim replaces the previous interim.
public struct DoubaoResultState: Sendable {
    public enum Commit: Sendable, Equatable {
        case rescued(String)
        case final(String)
    }

    public struct Update: Sendable, Equatable {
        public let partial: PartialTranscript
        public let text: String
        public let isInterim: Bool
        public let vadFinished: Bool
        public let nonstreamResult: Bool
        public let previousInterimLength: Int
        public let looksLikeNewUtterance: Bool
        public let commit: Commit?
    }

    public private(set) var committedSegments: [String] = []
    public private(set) var interimText: String = ""

    public init() {}

    public var finalText: String { committedSegments.joined() }
    public var rawText: String { finalText + interimText }
    public var displayText: String { TranscriptFormatter.normalize(rawText) }

    @discardableResult
    public mutating func ingest(resultJson: String) -> Update? {
        guard !resultJson.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(resultJson.utf8)) as? [String: Any] else {
            return nil
        }
        return ingest(object: object)
    }

    @discardableResult
    public mutating func ingest(object: [String: Any]) -> Update? {
        guard let results = object["results"] as? [[String: Any]], !results.isEmpty else {
            return nil
        }

        var text = ""
        var isInterim = true
        var vadFinished = false
        var nonstreamResult = false
        for result in results {
            if let value = result["text"] as? String, !value.isEmpty { text = value }
            if let value = result["is_interim"] as? Bool, !value { isInterim = false }
            if let value = result["is_vad_finished"] as? Bool, value { vadFinished = true }
            if let extra = result["extra"] as? [String: Any],
               let value = extra["nonstream_result"] as? Bool,
               value {
                nonstreamResult = true
            }
        }
        guard !text.isEmpty else { return nil }

        let previousInterimLength = interimText.count
        let isVadCommit = (!isInterim && vadFinished) || nonstreamResult
        // Doubao sometimes starts a new utterance without finalizing the prior
        // one. A dramatic text shrink commits that prior interim before adopting
        // the new utterance; otherwise long recordings lose all but the last one.
        let looksLikeNewUtterance = !isVadCommit
            && !interimText.isEmpty
            && ASRHypothesis.looksLikeNewUtterance(previous: interimText, candidate: text)

        let commit: Commit?
        if looksLikeNewUtterance {
            let rescued = interimText
            committedSegments.append(rescued)
            interimText = text
            commit = .rescued(rescued)
        } else if isVadCommit {
            committedSegments.append(text)
            interimText = ""
            commit = .final(text)
        } else {
            interimText = text
            commit = nil
        }

        return Update(
            partial: PartialTranscript(
                finalText: TranscriptFormatter.normalize(finalText),
                interimText: TranscriptFormatter.normalize(interimText)
            ),
            text: text,
            isInterim: isInterim,
            vadFinished: vadFinished,
            nonstreamResult: nonstreamResult,
            previousInterimLength: previousInterimLength,
            looksLikeNewUtterance: looksLikeNewUtterance,
            commit: commit
        )
    }
}
