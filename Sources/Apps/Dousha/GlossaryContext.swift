import Foundation

/// Glossary → Doubao `context` string encoding (QUA-133).
enum GlossaryContext {
    /// Maximum number of terms included in the context string. A glossary should
    /// bias recognition, not become a prompt-sized document — too long a context
    /// risks added latency and over-biasing.
    static let maxTerms = 50

    /// Maximum total length (characters) of the joined context string. Terms are
    /// added in order until appending the next would exceed this; the rest are
    /// dropped.
    static let maxChars = 500

    /// Separator between terms. `、` (Chinese enumeration comma) reads as a list
    /// to the recognizer, matching how the official IME's `context` carries free
    /// text.
    static let separator = "、"

    /// Encodes a glossary into the `context` string sent in StartSession.
    ///
    /// Cleans a raw glossary into a normalized term list: trim each term → drop
    /// empties → dedup (first-seen order) → keep at most `maxTerms`. This is the
    /// shape Soniox's `context.terms` array wants directly (it does its own
    /// hot-wording, so no joining or char cap is applied here — Soniox's own
    /// limit is ~10k chars, far above our `maxTerms` of short terms).
    static func normalize(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []

        for raw in terms {
            if kept.count >= maxTerms { break }
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if term.isEmpty { continue }
            if seen.contains(term) { continue }
            seen.insert(term)
            kept.append(term)
        }
        return kept
    }

    /// Encodes a glossary into the single `context` STRING used by Doubao
    /// (whose field is free-form text, not a term array).
    ///
    /// Pipeline: `normalize` → skip any term that would push the joined length
    /// past `maxChars` → join with `、`. A single oversized term is skipped
    /// rather than aborting the whole glossary, so one pathological entry can't
    /// silently empty the list. Returns `""` for empty / all-empty input. JSON
    /// escaping is the caller's concern (handled by `JSONSerialization`
    /// downstream), never done here.
    static func encode(_ terms: [String]) -> String {
        var kept: [String] = []
        var length = 0

        for term in normalize(terms) {
            // Length this term would add, including the separator if not first.
            let added = term.count + (kept.isEmpty ? 0 : separator.count)
            if length + added > maxChars { continue }
            kept.append(term)
            length += added
        }

        return kept.joined(separator: separator)
    }
}
