/// A local, deterministic text reconciler for streaming ASR snapshots
/// (QUA-263).
///
/// > **Status: reserved, not wired.** Pure logic + tests only — NOT part of
/// > the recording pipeline. Its output (`Operation`: stable-prefix /
/// > delete / insert) targets a typewriter-style insertion path.
/// > `TextInjector` is clipboard+⌘V by design (ARCHITECTURE.md §5) and the
/// > HUD's reveal animation already keeps the stable prefix stable, so there
/// > is no consumer of the `Operation` today. Re-evaluate only if injection
/// > becomes incremental (per-key backspace + retype). See
/// > `ARCHITECTURE.md` §7.
///
/// Streaming ASR revises the tail of a sentence as it refines its hypothesis.
/// Replacing the whole visible transcript on every snapshot causes visible
/// text jumps and target-app churn; this component instead converts two
/// consecutive transcript snapshots — the text currently visible and the new
/// ASR candidate — into the minimal tail edit (the shape the official-client
/// clues expose: `commonPrefixCount`, `replaceLength`, `replace_decision`):
///
///     keep the stable common prefix
///     delete the previous tail after it
///     insert the candidate's tail
///
/// Only the tail is ever edited — no common-*suffix* matching — because the
/// intended consumer is a typewriter-style insertion path that can only
/// backspace and retype at the end of what it wrote; a mid-string edit is
/// unreachable without cursor movement.
///
/// Semantics, all deliberate:
///
/// - **Units are extended grapheme clusters** (Swift `Character`), so counts
///   line up with `String.count`/`prefix`/`dropLast` and an edit can never
///   split an emoji or a combining sequence. `deleteGraphemeCount` is named
///   for its unit on purpose: it is NOT a backspace-key count — some target
///   apps delete decomposed clusters scalar-by-scalar, and translating
///   grapheme counts into per-app deletion events is the insertion layer's
///   concern, not modelled here.
/// - **Prefix matching is scalar-exact**, not canonical-equivalence: two
///   clusters count as stable only when their unicode scalars are identical.
///   This guarantees `apply(to: previous) == candidate` byte-for-byte, so the
///   visible text converges on exactly what the engine sent.
/// - **No normalization.** Punctuation, width (，vs ,), and whitespace
///   differences are part of ASR behavior and reconcile as real edits
///   (QUA-263: conservative normalization — preserve differences by default).
/// - **An empty candidate never erases non-empty visible text.** Streaming
///   engines emit spurious empty snapshots (session resets, keepalive
///   frames); wiping and retyping the transcript on one is exactly the churn
///   this component exists to avoid, so it reconciles as `.noChange` — the
///   same ignore-empty rule as `ASRSegmentModel.observePartial`. Clearing
///   text is a caller decision (cancel), not a reconciliation.
public enum StreamingTextReconciler {
    /// The tail edit that turns the previous visible text into the candidate:
    /// keep the first `stablePrefixCount` characters of `previous`, delete
    /// the `deleteGraphemeCount` characters after them, insert `insertion`.
    public struct Operation: Sendable, Equatable {
        /// Leading characters (grapheme clusters) of `previous` that stay
        /// untouched.
        public let stablePrefixCount: Int
        /// Grapheme clusters of `previous` to delete after the stable prefix
        /// (always `previous.count - stablePrefixCount`, except for the held
        /// empty candidate where it is 0). Not a backspace-key count — see
        /// the unit note in the type comment.
        public let deleteGraphemeCount: Int
        /// Text to insert where the deleted tail was.
        public let insertion: String

        /// Classification per QUA-263: no-op, append-only, or replace-tail.
        public var kind: Kind {
            if deleteGraphemeCount > 0 { return .replaceTail }
            return insertion.isEmpty ? .noChange : .appendOnly
        }

        /// Replay the edit. Yields the candidate exactly — except for a held
        /// empty candidate, where it yields `previous` unchanged.
        public func apply(to previous: String) -> String {
            String(previous.prefix(stablePrefixCount)) + insertion
        }
    }

    public enum Kind: Sendable, Equatable {
        /// Snapshots already agree (or the empty candidate was held).
        case noChange
        /// The candidate only extends the visible text.
        case appendOnly
        /// Part of the visible tail must be deleted first. Covers pure
        /// truncation too (`insertion` empty).
        case replaceTail
    }

    /// Reconcile the visible text with a new ASR snapshot. Pure and total:
    /// no state, no clocks, no Accessibility — same inputs, same operation.
    public static func reconcile(previous: String, candidate: String) -> Operation {
        if candidate.isEmpty {
            // Held: see the empty-candidate rule in the type comment.
            return Operation(stablePrefixCount: previous.count, deleteGraphemeCount: 0,
                             insertion: "")
        }

        var prefixCount = 0
        var previousIndex = previous.startIndex
        var candidateIndex = candidate.startIndex
        while previousIndex < previous.endIndex, candidateIndex < candidate.endIndex,
              previous[previousIndex].unicodeScalars
                  .elementsEqual(candidate[candidateIndex].unicodeScalars) {
            prefixCount += 1
            previous.formIndex(after: &previousIndex)
            candidate.formIndex(after: &candidateIndex)
        }

        return Operation(stablePrefixCount: prefixCount,
                         deleteGraphemeCount: previous.count - prefixCount,
                         insertion: String(candidate[candidateIndex...]))
    }
}
