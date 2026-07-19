import Foundation
import ASRSupport

/// Pure, `Sendable`, unit-testable parser for Soniox real-time STT responses.
///
/// Keeping all protocol decoding out of the networking actor means the
/// finalize/interim accumulation logic can be tested without a socket.
///
/// Soniox emits incremental token batches. Each batch is a JSON object:
///
///     { "tokens": [ { "text", "is_final", "translation_status"?, ... } ],
///       "finished"?: Bool, "error_code"?, "error_message"? }
///
/// Accumulation rules (mirrors the JS reference `_handleResponse`):
/// - `is_final: true` token texts are *appended* to the running final string;
///   the server does NOT re-send them in later batches (delta accumulation).
/// - `is_final: false` tokens are the live interim for the current utterance;
///   they *replace* the interim buffer on every batch (not accumulated).
/// - A token whose `text` is `"<end>"` is an endpoint marker, not text: it
///   flushes the interim (we clear it) and is never appended.
/// - `translation_status` of `original`, `none`, or missing is treated as
///   transcript text. `translation` tokens are ignored (translation is out of
///   scope for plain dictation).
public struct SonioxResponseParser: Sendable {
    /// Finalized transcript accumulated across all batches so far.
    public private(set) var finalText: String = ""
    /// Live interim for the not-yet-finalized utterance (replaced per batch).
    public private(set) var interimText: String = ""
    /// True once a batch reported `"finished": true`.
    public private(set) var isFinished: Bool = false
    /// Error message from a batch carrying `error_code`/`error_message`, if any.
    public private(set) var errorMessage: String?

    public init() {}

    /// The text to surface live: finalized prefix plus the current interim,
    /// with Soniox's spacing normalised — stray full-width-punctuation spaces
    /// stripped, missing CJK<->Latin spaces inserted (QUA-173).
    public var displayText: String { TranscriptFormatter.normalize(finalText + interimText) }

    /// Outcome of ingesting one batch, so the actor can react (deliver partial,
    /// signal finished, deliver error) without re-reading parser state.
    public struct Update: Sendable, Equatable {
        public let finalText: String
        public let interimText: String
        public let didProduceContent: Bool
        public let finished: Bool
        public let errorMessage: String?
    }

    /// Ingest one raw JSON batch (the UTF-8 bytes of a server text frame).
    /// Returns nil if the payload isn't a JSON object we recognise.
    @discardableResult
    public mutating func ingest(jsonData: Data) -> Update? {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }
        return ingest(object: obj)
    }

    @discardableResult
    public mutating func ingest(object obj: [String: Any]) -> Update? {
        // Errors first — an error batch may carry no tokens.
        if let code = obj["error_code"], !(code is NSNull) {
            let msg = (obj["error_message"] as? String) ?? "Soniox error (\(code))"
            errorMessage = msg
            return Update(finalText: finalText, interimText: interimText,
                          didProduceContent: false, finished: false, errorMessage: msg)
        }

        // `finished` MUST be read before any "tokens empty" early return — the
        // finished batch can carry an empty tokens array.
        let finishedNow = (obj["finished"] as? Bool) ?? false
        if finishedNow { isFinished = true }

        let tokens = (obj["tokens"] as? [[String: Any]]) ?? []

        var newInterim = ""
        var appendedFinal = false
        for token in tokens {
            let text = (token["text"] as? String) ?? ""
            let status = (token["translation_status"] as? String)
            // Skip translation tokens entirely (plain dictation).
            if status == "translation" { continue }
            // `<end>` is an endpoint marker: flush interim, never append.
            if text == "<end>" {
                newInterim = ""
                continue
            }
            let isFinal = (token["is_final"] as? Bool) ?? false
            if isFinal {
                finalText += text
                appendedFinal = true
            } else {
                newInterim += text
            }
        }
        // Interim is replaced per batch (only when this batch carried tokens —
        // a bare `finished` batch with no tokens must not wipe a valid interim,
        // though in practice the final batch finalizes everything).
        if !tokens.isEmpty {
            interimText = newInterim
        }

        // Once finished, the transcript is whatever was finalized — there is no
        // pending interim. Enforce this invariant so `displayText` (used as the
        // result text) never carries a stale interim tail after completion,
        // even for a bare `{"finished": true}` batch with no tokens.
        if isFinished {
            interimText = ""
        }

        let produced = appendedFinal || !interimText.isEmpty
        // Deliver normalised text so the live HUD matches the committed result's
        // spacing (QUA-173). `displayText` normalises the combined string for the
        // committed/pasted result.
        return Update(
            finalText: TranscriptFormatter.normalize(finalText),
            interimText: TranscriptFormatter.normalize(interimText),
            didProduceContent: produced,
            finished: finishedNow,
            errorMessage: nil
        )
    }
}
