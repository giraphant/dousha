import Foundation

/// Local-only deterministic correction layer for final ASR text (QUA-264).
///
/// Runs once per dictation, after the engines' streaming normalization and
/// before optional LLM refinement / injection. Vendor-neutral: the same rules
/// apply to Doubao, Soniox, and Apple Speech output. Everything here is pure
/// string transformation — no network, no persistence, no telemetry (the
/// privacy-sensitive remote NER / user-word / modify-pair paths found in the
/// QUA-258 reverse-engineering are explicitly out of scope).
///
/// `correct` is a *pipeline of rules in a fixed, documented order*:
///
///   1. **User replacements** — caller-supplied exact (case-sensitive) phrase
///      fixes, applied in list order. First so the user's rules see the text
///      closest to what the engine produced, and so their output is then
///      re-checked by the built-in rules below (casing, spacing).
///   2. **Term casing** — known terms (built-in product names + the user's
///      glossary hot-words) matched case-insensitively at word boundaries and
///      rewritten to their canonical casing (`claude code` → `Claude Code`).
///   3. **Spacing** — `TranscriptFormatter.normalize`, re-run because rules 1–2
///      can create fresh CJK↔Latin seams (`把阿派=>API` yields `把API` which
///      needs its 盘古 space). Idempotent, so re-running over already-normalized
///      engine output is safe.
///   4. **Trailing punctuation cleanup** — collapse a doubled terminal mark and
///      drop dangling clause separators at the very end of the dictation.
///
/// Every rule is conservative by design: no semantic rewrites, no built-in
/// homophone dictionaries (`杰森` is as often the name Jason as it is JSON —
/// that call needs context we don't have; it stays in the user's own
/// replacement list or the optional LLM refiner). The whole layer is a no-op
/// when `isEnabled` is false.
///
/// The layer runs **exactly once** per dictation (`RecordingController`
/// applies it to the single terminal `.final`). Rules 2–4 are idempotent, but
/// a user replacement whose output re-contains its own match (`foo=>foo bar`)
/// would compound if re-run — the run-once contract, not per-rule idempotency,
/// is what keeps user rules safe.
public struct TranscriptCorrector: Sendable {
    /// One user-defined phrase fix: every occurrence of `match` becomes
    /// `replacement`. Matching is case-sensitive and, when `match` starts/ends
    /// with an ASCII letter or digit, word-bounded (so `cat → Kat` cannot
    /// mangle "category"). An empty `replacement` deletes the phrase.
    public struct Replacement: Sendable, Equatable {
        public let match: String
        public let replacement: String

        /// Nil when `match` trims to empty — a rule that matches nothing.
        public init?(match: String, replacement: String) {
            let m = match.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !m.isEmpty else { return nil }
            self.match = m
            self.replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Parses the stored rule format `wrong=>right` (first `=>` wins, so a
        /// replacement may itself contain `=>`). Nil for lines without the
        /// separator or with an empty left side.
        public static func parse(_ line: String) -> Replacement? {
            guard let sep = line.range(of: "=>") else { return nil }
            return Replacement(match: String(line[..<sep.lowerBound]),
                               replacement: String(line[sep.upperBound...]))
        }
    }

    /// Master switch — false makes `correct` the identity function.
    public var isEnabled: Bool
    /// User phrase fixes, applied in list order (rule 1).
    public var replacements: [Replacement]
    /// Canonical casings enforced by rule 2. On case-insensitive duplicates the
    /// earlier entry wins, so callers should put user terms before built-ins.
    public var casingTerms: [String]

    public init(isEnabled: Bool = true,
                replacements: [Replacement] = [],
                casingTerms: [String] = TranscriptCorrector.builtinCasingTerms) {
        self.isEnabled = isEnabled
        self.replacements = replacements
        self.casingTerms = casingTerms
    }

    /// Built-in canonical casings. Deliberately limited to names that are not
    /// also common English words or phrases — `Swift`, `Go`, `Linear`, `Slack`,
    /// `Python` (the snake), `Docker` (a dock worker), `App Store` (a generic
    /// app store) are all excluded because "a swift response" and "a python
    /// escaped" must survive. Users add their own terms (with their casing)
    /// through the glossary. Multi-word terms match on a single ASCII space.
    public static let builtinCasingTerms: [String] = [
        "Claude Code", "VS Code",
        "ChatGPT", "OpenAI", "Anthropic", "Claude",
        "GitHub", "GitLab",
        "JavaScript", "TypeScript", "Kubernetes",
        "iPhone", "iPad", "macOS", "iOS", "Xcode",
        "Dousha", "Doubao", "Soniox",
        "AI", "API", "ASR", "CLI", "CPU", "CSS", "GPU", "HTML", "HTTP", "HTTPS",
        "IDE", "JSON", "LLM", "PDF", "SDK", "SQL", "UI", "URL",
    ]

    /// Run the full correction pipeline. Pure, deterministic, idempotent.
    public func correct(_ text: String) -> String {
        guard isEnabled, !text.isEmpty else { return text }
        var s = text
        // Rule 1: user replacements, in list order.
        for rule in replacements {
            s = Self.replaceAll(of: rule.match, with: rule.replacement, in: s,
                                caseInsensitive: false)
        }
        // Rule 2: canonical term casing, longest term first so a multi-word
        // term is never shadowed by one of its words.
        for term in Self.casingCandidates(casingTerms) {
            s = Self.replaceAll(of: term, with: term, in: s, caseInsensitive: true)
        }
        // Rule 3: repair spacing around any seams rules 1–2 introduced.
        s = TranscriptFormatter.normalize(s)
        // Rule 4: tail punctuation cleanup.
        s = Self.cleanTrailingPunctuation(s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Rule 2 helpers

    /// Cleans the raw casing list into the order rule 2 applies: trimmed, no
    /// empties, only terms that actually carry letter case, de-duplicated
    /// case-insensitively (first entry wins), longest first (stable).
    static func casingCandidates(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        for raw in terms {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            // A term with no cased letters (pure CJK / digits) can't be re-cased.
            guard term.lowercased() != term.uppercased() else { continue }
            guard seen.insert(term.lowercased()).inserted else { continue }
            kept.append(term)
        }
        // Stable longest-first: enumerate to keep first-seen order among equals.
        return kept.enumerated()
            .sorted { ($1.element.count, $0.offset) < ($0.element.count, $1.offset) }
            .map(\.element)
    }

    // MARK: - Boundary-aware replace

    /// Replace every occurrence of `match`, skipping occurrences that would
    /// split a Latin word: when `match` starts (ends) with a Latin letter or
    /// digit, the character before (after) the occurrence must not be one.
    /// CJK neighbours are fine — `中文api` re-cases to `中文API`.
    static func replaceAll(of match: String, with replacement: String,
                           in text: String, caseInsensitive: Bool) -> String {
        guard !match.isEmpty else { return text }
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        let boundedStart = isLatinWordJoining(match.first!)
        let boundedEnd = isLatinWordJoining(match.last!)

        var result = ""
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let r = text.range(of: match, options: options,
                                 range: searchStart..<text.endIndex) {
            var wordBounded = true
            if boundedStart, r.lowerBound > text.startIndex,
               isLatinWordJoining(text[text.index(before: r.lowerBound)]) {
                wordBounded = false
            }
            if boundedEnd, r.upperBound < text.endIndex,
               isLatinWordJoining(text[r.upperBound]) {
                wordBounded = false
            }
            if wordBounded {
                result += text[searchStart..<r.lowerBound]
                result += replacement
                searchStart = r.upperBound
                // A deletion between two spaces ("so um yeah") would leave a
                // double space — eat one so the join reads naturally.
                if replacement.isEmpty, result.last == " ",
                   searchStart < text.endIndex, text[searchStart] == " " {
                    searchStart = text.index(after: searchStart)
                }
            } else {
                // Skip just this occurrence's first character and keep scanning.
                let next = text.index(after: r.lowerBound)
                result += text[searchStart..<next]
                searchStart = next
            }
        }
        result += text[searchStart...]
        return result
    }

    // MARK: - Rule 4: trailing punctuation

    /// Terminal sentence marks eligible for the doubled-mark collapse.
    private static let terminalMarks: Set<Character> = ["。", "．", ".", "？", "?", "！", "!"]
    /// Clause separators that are never wanted at the very end of a dictation
    /// (engine pause artifacts). Full-width Chinese marks only: an English
    /// trailing comma can be deliberate ("Dear Alice,"), and `：`/`：` is a
    /// legitimate ending ("如下："), so both survive.
    private static let danglingMarks: Set<Character> = ["，", "、"]

    /// Tail-only cleanup: drop any dangling clause separators (`然后，` → `然后`),
    /// then collapse an *exactly doubled* terminal mark (`了。。` → `了。`).
    /// The collapse deliberately skips two shapes it can't judge safely: a run
    /// of three or more (`真的...` reads as an intentional ellipsis) and a pair
    /// preceded by a *different* terminal mark (`。..` — a mixed-punct tail the
    /// upstream formatter can produce from a widened ellipsis; rewriting it
    /// risks making it worse). Dangling-drop runs first so the collapse sees
    /// the true tail (`。。，` → `。` in one pass — order is what keeps this
    /// idempotent).
    static func cleanTrailingPunctuation(_ s: String) -> String {
        var chars = Array(s)
        while let last = chars.last, danglingMarks.contains(last) {
            chars.removeLast()
        }
        if chars.count >= 2, let last = chars.last, terminalMarks.contains(last),
           chars[chars.count - 2] == last,
           (chars.count < 3 || !terminalMarks.contains(chars[chars.count - 3])) {
            chars.removeLast()
        }
        return String(chars)
    }

    // MARK: - Character classes

    /// Characters that continue a Latin word for boundary purposes: ASCII
    /// letters/digits plus the extended-Latin letter blocks (é, ñ, ø, …), so a
    /// term embedded in an accented word (`éapi`, `cafés`) is never split.
    /// Wider than `TranscriptFormatter`'s ASCII-only "Latin side" on purpose —
    /// there the class decides where to *add* spaces (conservative = narrow);
    /// here it decides where a replacement must *not* fire (conservative =
    /// wide). CJK is deliberately not word-joining.
    private static func isLatinWordJoining(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value, ch.unicodeScalars.count == 1 else {
            return false
        }
        return (0x30...0x39).contains(v)      // 0-9
            || (0x41...0x5A).contains(v)      // A-Z
            || (0x61...0x7A).contains(v)      // a-z
            || (0xC0...0xFF).contains(v) && v != 0xD7 && v != 0xF7  // Latin-1 letters (not ×÷)
            || (0x100...0x24F).contains(v)    // Latin Extended-A/B
            || (0x1E00...0x1EFF).contains(v)  // Latin Extended Additional
    }
}
