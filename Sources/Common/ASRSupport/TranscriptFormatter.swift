import Foundation

/// Provider-neutral "last pass before the cursor" for ASR output (QUA-173).
///
/// Both Soniox and Doubao hand back text whose spacing around the CJK/Latin
/// seam is inconsistent. Rather than fix that per provider, every engine routes
/// its final + interim text through `TranscriptFormatter.normalize` so the user
/// sees uniform formatting no matter which backend produced it.
///
/// `normalize` is a *pipeline of rules*. Today it carries the two spacing rules
/// below; this is the seam where future rules (e.g. casing of known glossary
/// terms) would attach. Every rule must be pure and idempotent — `normalize`
/// runs on every streamed batch, so a non-idempotent rule would compound.
public enum TranscriptFormatter {
    /// Run the full formatting pipeline. Pure, O(n), idempotent.
    public static func normalize(_ s: String) -> String {
        // Order: widen stray half-width punctuation first so that, e.g.,
        // "你好, 世界" becomes "你好， 世界" and the tighten pass then sees a
        // full-width mark and strips the space. Then strip stray Chinese-side
        // spaces, then insert the missing CJK<->Latin spaces. The latter two
        // key off disjoint character classes (Chinese punctuation / Han
        // ideographs vs. the CJK<->Latin seam) so they don't fight, but tidying
        // first keeps the pangu pass reasoning on clean boundaries.
        pangu(tightenCJKSpaces(widenCJKPunctuation(s)))
    }

    // MARK: - Rule: widen half-width punctuation in Chinese context (QUA-194)

    /// Half-width -> full-width mapping for the sentence marks Soniox sometimes
    /// emits as ASCII inside Chinese text (its token language-tagging flickers
    /// at zh/en boundaries).
    private static let fullWidthPunct: [Character: Character] = [
        ",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；",
    ]

    /// Convert ASCII `, . ? ! : ;` to their full-width forms when they sit in
    /// Han context — Soniox occasionally returns half-width marks mid-Chinese
    /// (QUA-194). Deliberately conservative so genuine half-width uses survive:
    ///   - converts when the previous or next character is a Han ideograph
    ///     (`你好,世界`, `用Cursor,然后`), so pure English (`Hello, world.`),
    ///     decimals (`3.5`), thousands separators (`5,000`), and times (`2:30`)
    ///     are untouched;
    ///   - `.` additionally requires the next char not be ASCII alphanumeric,
    ///     so dotted identifiers right after Han (`叫.NET`) keep their dot.
    /// Han-only context (not kana/Hangul) — those scripts mix with ASCII
    /// punctuation legitimately.
    public static func widenCJKPunctuation(_ s: String) -> String {
        // Fast path: no candidate ASCII punctuation => nothing to widen.
        // Bytes of , . ? ! : ; in UTF-8 (all single-byte ASCII).
        let punctBytes: Set<UInt8> = [0x2C, 0x2E, 0x3F, 0x21, 0x3A, 0x3B]
        guard s.utf8.contains(where: { punctBytes.contains($0) }) else { return s }

        let chars = Array(s)
        var out = String()
        out.reserveCapacity(chars.count)
        for (i, ch) in chars.enumerated() {
            guard let wide = fullWidthPunct[ch] else {
                out.append(ch)
                continue
            }
            let prev = i > 0 ? chars[i - 1] : nil
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            let prevHan = prev.map(isHan) ?? false
            let nextHan = next.map(isHan) ?? false
            let nextAlnum = next.map(isLatinAlnum) ?? false
            let convert: Bool
            if ch == "." {
                convert = nextHan || (prevHan && !nextAlnum)
            } else {
                convert = prevHan || nextHan
            }
            out.append(convert ? wide : ch)
        }
        return out
    }

    // MARK: - Rule: strip stray spaces on the Chinese side

    /// Drop the ASCII spaces Soniox/Doubao bake into Chinese text. Two shapes,
    /// both stemming from the engines starting a new (English-spaced) segment at
    /// a speech pause:
    ///   - a space next to a full-width punctuation mark (`你好。 世界`), and
    ///   - a space wedged between two Han ideographs when the pause lands
    ///     mid-sentence (`我觉得 这个` -> `我觉得这个`).
    /// Neither is ever wanted in Chinese. A space between CJK and Latin/digits is
    /// correct and survives — Han-vs-Han only, so Korean/Hangul (which *does* use
    /// inter-word spaces) is untouched.
    public static func tightenCJKSpaces(_ s: String) -> String {
        // Fast path: no ASCII space => nothing to strip.
        guard s.utf8.contains(0x20) else { return s }

        let chars = Array(s)
        var out = String()
        out.reserveCapacity(chars.count)
        for (i, ch) in chars.enumerated() {
            if ch == " " {
                let prev = i > 0 ? chars[i - 1] : nil
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let prevPunct = prev.map(isCJKPunctuation) ?? false
                let nextPunct = next.map(isCJKPunctuation) ?? false
                let bothHan = (prev.map(isHan) ?? false) && (next.map(isHan) ?? false)
                if prevPunct || nextPunct || bothHan {
                    continue // drop a stray Chinese-side space
                }
            }
            out.append(ch)
        }
        return out
    }

    // MARK: - Rule: 盘古之白 (insert missing CJK<->Latin spaces)

    /// Insert a single space at every CJK<->Latin/digit boundary that doesn't
    /// already have whitespace (`strip掉` -> `strip 掉`, `第3章` -> `第 3 章`).
    /// Conservative — only ASCII letters and digits count as the "Latin" side,
    /// and only Han/Kana/Hangul as the CJK side, so full-width punctuation never
    /// gains a leading space (`bug，` / `5000，` stay put).
    public static func pangu(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count > 1 else { return s }
        var out = String()
        out.reserveCapacity(chars.count + 8)
        for i in 0..<chars.count {
            let a = chars[i]
            out.append(a)
            guard i + 1 < chars.count else { break }
            let b = chars[i + 1]
            if (isCJKWord(a) && isLatinAlnum(b)) || (isLatinAlnum(a) && isCJKWord(b)) {
                out.append(" ")
            }
        }
        return out
    }

    // MARK: - Character classes

    private static func isLatinAlnum(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return (0x30...0x39).contains(v.value)   // 0-9
            || (0x41...0x5A).contains(v.value)   // A-Z
            || (0x61...0x7A).contains(v.value)   // a-z
    }

    /// True only for Han ideographs — the script that never uses inter-character
    /// spaces, so a space between two of them is always stray. Narrower than
    /// `isCJKWord` on purpose: excludes Hangul, where spaces are meaningful.
    private static func isHan(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) { return true }   // CJK Unified Ideographs
            if (0x3400...0x4DBF).contains(v) { return true }   // CJK Ext. A
            if (0xF900...0xFAFF).contains(v) { return true }   // CJK Compatibility Ideographs
        }
        return false
    }

    /// True for the CJK *word* characters that 盘古之白 spaces against Latin —
    /// Han ideographs, kana, Hangul. Deliberately NOT punctuation/full-width
    /// forms, so we never insert a space before a Chinese comma/period.
    private static func isCJKWord(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) { return true }   // CJK Unified Ideographs
            if (0x3400...0x4DBF).contains(v) { return true }   // CJK Ext. A
            if (0xF900...0xFAFF).contains(v) { return true }   // CJK Compatibility Ideographs
            if (0x3040...0x30FF).contains(v) { return true }   // Hiragana + Katakana
            if (0xAC00...0xD7AF).contains(v) { return true }   // Hangul syllables
        }
        return false
    }

    /// True for CJK symbols/punctuation and full-width forms — the marks that
    /// should never carry an adjacent ASCII space. Deliberately excludes the
    /// shared curly quotes (U+2018/2019/201C/201D), which double as English
    /// punctuation, to avoid mangling Latin text.
    private static func isCJKPunctuation(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            // CJK Symbols and Punctuation: 。、《》「」『』【】〈〉…— and the
            // ideographic space.
            if (0x3000...0x303F).contains(v) { return true }
            // Full-width forms: ，！？：；（）％＃ and other full-width ASCII.
            if (0xFF00...0xFFEF).contains(v) { return true }
        }
        return false
    }
}
