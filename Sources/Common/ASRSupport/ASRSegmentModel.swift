import Foundation

/// A local, vendor-neutral, VAD-like segment model layered above the ASR
/// engines (QUA-265).
///
/// Dictation is modelled as an ordered sequence of utterance segments moving
/// through a one-way lifecycle:
///
///     active ──local pause──▶ pending ──engine final──▶ recentlyFinalized ──window──▶ committed
///        └───────────── engine final ──────────────────▲
///
/// - `active`: the utterance currently being built by interim hypotheses.
/// - `pending`: hit a *local* pause-like boundary (no hypothesis change for
///   `Config.pauseBoundary`) with no engine final yet; a continuing hypothesis
///   for the same utterance re-activates it.
/// - `recentlyFinalized`: the engine finalized it; a late revision (e.g. a
///   second-pass / non-streaming re-recognition) may still replace its text
///   until `Config.revisionWindow` elapses.
/// - `committed`: immutable — the revision floor. Revisions never reach here.
///
/// "VAD-like" refers only to the shape of the model (utterance segmentation
/// driven by pauses and finals, inspired by the segment concepts the official
/// clients expose: eos-silence timeouts, sentence-max limits, VAD-final
/// flags). This is NOT audio processing: it never sees samples and performs
/// no real voice-activity detection, no denoising, and no speaker
/// separation/focus (QUA-258 non-goals). Inputs are ASR text events plus
/// caller-supplied timestamps, which keeps the model pure and deterministic.
///
/// Timestamps are seconds on any single monotonic clock the caller chooses;
/// the model never reads a clock itself. Time-based transitions run lazily at
/// the start of every event (and on demand via `tick(at:)`), so replaying
/// recorded event times reproduces identical state in tests.
///
/// A sentence-max-seconds-style *forced* boundary is deliberately not
/// modelled: without engine cooperation a forced local boundary fights the
/// cumulative hypothesis stream (the parked prefix would re-arrive inside
/// every later hypothesis). The engines already enforce their own maximums.
///
/// Engine mapping (adapters own this; the model stays engine-neutral):
/// - Doubao: each cumulative hypothesis → `observePartial`; a VAD-final
///   commit → `observeFinal`; a `nonstream_result` re-recognition →
///   `observeRevision`.
/// - Soniox: the growing non-final token tail → `observePartial`; the
///   utterance text at an `<end>` endpoint marker → `observeFinal`.
public struct ASRSegmentModel: Sendable, Equatable {
    /// Local timing thresholds. Conservative defaults; nothing user-facing is
    /// wired to them yet (QUA-265 acceptance: no behavior change).
    public struct Config: Sendable, Equatable {
        /// Pause-like boundary: with no hypothesis *change* for this long,
        /// the active segment is parked as `.pending` (analogous to an
        /// eos-silence timeout, but computed from text-event timing only).
        public var pauseBoundary: TimeInterval
        /// How long a finalized segment stays revisable before committing.
        public var revisionWindow: TimeInterval

        public init(pauseBoundary: TimeInterval = 1.5, revisionWindow: TimeInterval = 3.0) {
            self.pauseBoundary = pauseBoundary
            self.revisionWindow = revisionWindow
        }
    }

    public enum State: Sendable, Equatable {
        case active
        case pending
        case recentlyFinalized
        case committed
    }

    public struct Segment: Sendable, Equatable {
        /// Raw utterance text as the engine reported it. Formatting stays in
        /// `TranscriptFormatter`; this model never normalizes.
        public internal(set) var text: String
        public internal(set) var state: State
        /// Last time `text` actually changed. A re-sent identical hypothesis
        /// does not refresh this — that is what makes a pause observable.
        public internal(set) var lastChangeAt: TimeInterval
        public internal(set) var finalizedAt: TimeInterval?
    }

    public let config: Config
    /// All segments in utterance order. States are monotone along the array:
    /// committed*, (recentlyFinalized|pending)*, active?.
    public private(set) var segments: [Segment] = []

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Queries (the questions QUA-265 asks the model to answer)

    /// Text of the current active utterance ("" when none).
    public var activeText: String { joinedText(in: .active) }
    /// Text parked at a local pause-like boundary, awaiting an engine final.
    public var pendingText: String { joinedText(in: .pending) }
    /// Engine-finalized text still inside the revision window.
    public var recentlyFinalizedText: String { joinedText(in: .recentlyFinalized) }
    /// The revision floor: immutable text no late revision may modify.
    public var committedText: String { joinedText(in: .committed) }
    /// The whole transcript so far, in utterance order (raw concatenation,
    /// matching how the engines' cumulative text composes).
    public var fullText: String { segments.map(\.text).joined() }

    private func joinedText(in state: State) -> String {
        segments.filter { $0.state == state }.map(\.text).joined()
    }

    // MARK: - Events

    /// Run only the time-based transitions (pause parking, revision-window
    /// commits) up to `now`. Every observe event does this implicitly first.
    public mutating func tick(at now: TimeInterval) {
        for index in segments.indices {
            switch segments[index].state {
            case .recentlyFinalized:
                if let finalizedAt = segments[index].finalizedAt,
                   now - finalizedAt >= config.revisionWindow {
                    segments[index].state = .committed
                }
            case .active:
                if now - segments[index].lastChangeAt >= config.pauseBoundary {
                    segments[index].state = .pending
                }
            case .pending, .committed:
                break
            }
        }
    }

    /// Ingest an interim hypothesis for the current utterance (cumulative for
    /// that utterance, replacing the previous hypothesis — the shape every
    /// streaming engine here emits).
    public mutating func observePartial(_ text: String, at now: TimeInterval) {
        tick(at: now)
        guard !text.isEmpty else { return }

        guard let tail = segments.indices.last,
              segments[tail].state == .active || segments[tail].state == .pending else {
            segments.append(Segment(text: text, state: .active, lastChangeAt: now,
                                    finalizedAt: nil))
            return
        }

        // A dramatic hypothesis shrink means the engine silently moved on to a
        // new utterance without finalizing the prior one (same heuristic as
        // DoubaoResultState's rescue): park the old text, start fresh.
        let previous = segments[tail].text
        let looksLikeNewUtterance = text.count * 2 < previous.count && !previous.hasPrefix(text)
        if looksLikeNewUtterance {
            segments[tail].state = .pending
            segments.append(Segment(text: text, state: .active, lastChangeAt: now,
                                    finalizedAt: nil))
            return
        }

        // Same utterance continuing — re-activates a pause-parked segment.
        segments[tail].state = .active
        if text != previous {
            segments[tail].text = text
            segments[tail].lastChangeAt = now
        }
    }

    /// Ingest an engine final for one utterance. Resolves the earliest
    /// unresolved (pending, then active) segment; `text` replaces the local
    /// hypothesis when non-empty, otherwise the local text stands (an
    /// endpoint marker carrying no new text). A final with no unresolved
    /// segment starts and finalizes a segment of its own.
    public mutating func observeFinal(_ text: String, at now: TimeInterval) {
        tick(at: now)

        if let index = segments.firstIndex(where: { $0.state == .pending || $0.state == .active }) {
            if !text.isEmpty, text != segments[index].text {
                segments[index].text = text
                segments[index].lastChangeAt = now
            }
            segments[index].state = .recentlyFinalized
            segments[index].finalizedAt = now
            return
        }
        guard !text.isEmpty else { return }
        segments.append(Segment(text: text, state: .recentlyFinalized, lastChangeAt: now,
                                finalizedAt: now))
    }

    /// Ingest a late revision (e.g. a second-pass re-recognition of the last
    /// utterance). It may only replace the most recent `.recentlyFinalized`
    /// segment; returns false — revision rejected — once everything has
    /// committed. The original `finalizedAt` stands, so a revision cannot
    /// extend its own window.
    @discardableResult
    public mutating func observeRevision(_ text: String, at now: TimeInterval) -> Bool {
        tick(at: now)
        guard !text.isEmpty,
              let index = segments.lastIndex(where: { $0.state == .recentlyFinalized }) else {
            return false
        }
        if text != segments[index].text {
            segments[index].text = text
            segments[index].lastChangeAt = now
        }
        return true
    }

    /// Stop/final flush: commit every segment (active and pending included)
    /// and return the full transcript — the one terminal result a recording
    /// yields. Calling again returns the same text and changes nothing.
    @discardableResult
    public mutating func flushOnStop(at now: TimeInterval) -> String {
        for index in segments.indices where segments[index].state != .committed {
            if segments[index].finalizedAt == nil {
                segments[index].finalizedAt = now
            }
            segments[index].state = .committed
        }
        return fullText
    }
}
