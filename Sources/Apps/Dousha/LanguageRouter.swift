import Foundation

/// Picks which engine's transcript to use for a recording, by the language
/// composition of the text. Pure value type — no I/O, fully unit-testable.
///
/// Per-recording routing (not per-utterance): engines return one joined
/// transcript each, and their VAD boundaries don't align, so we classify the
/// whole text and pick one engine's reading. The slots are configured in
/// Settings; the primary engine (HUD source) is derived from `prefs.language`,
/// not stored here.
struct LanguageRouter: Equatable {
    let chineseEngine: Engine
    let englishEngine: Engine
    let mixedEngine: Engine

    /// ≥95% CJK among classifiable chars → Chinese engine.
    static let chineseThreshold: Double = 0.95
    /// >50% Latin among classifiable chars → English engine.
    static let englishThreshold: Double = 0.50

    // MARK: - Composition ratios (pure)

    /// True for Han ideographs and Japanese kana (treated as non-Latin "CJK").
    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF,   // Hiragana + Katakana
             0x3400...0x4DBF,   // CJK Ext A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF:   // CJK Compatibility Ideographs
            return true
        default:
            return false
        }
    }

    /// ASCII Latin letters (the English signal).
    static func isLatinLetter(_ s: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(Int(s.value)) || (0x61...0x7A).contains(Int(s.value))
    }

    /// Counts only classifiable chars (CJK + Latin letters); whitespace,
    /// punctuation, and digits are ignored so they can't skew the ratio.
    static func composition(_ text: String) -> (cjk: Double, latin: Double) {
        var cjk = 0, latin = 0
        for ch in text {
            guard let s = ch.unicodeScalars.first else { continue }
            if isCJK(s) { cjk += 1 }
            else if isLatinLetter(s) { latin += 1 }
        }
        let total = cjk + latin
        guard total > 0 else { return (0, 0) }
        return (Double(cjk) / Double(total), Double(latin) / Double(total))
    }

    /// Which slot engine should serve text of this composition.
    func slot(forScoreText text: String) -> Engine {
        let (cjk, latin) = Self.composition(text)
        if cjk >= Self.chineseThreshold { return chineseEngine }
        if latin > Self.englishThreshold { return englishEngine }
        return mixedEngine
    }

    // MARK: - Result selection

    /// Pick the engine whose transcript to use.
    ///
    /// - `results`: each engine's final text (only engines that ran + survived;
    ///   empties allowed).
    /// - `primary`: the primary engine (HUD source / preferred scoring text).
    ///
    /// Scores `primary`'s text if non-empty, else the first non-empty result in
    /// a stable order; routes to the matching slot; if that slot's result is
    /// empty, falls through to any non-empty result; returns nil if all empty.
    func pickBest(results: [Engine: String], primary: Engine) -> (engine: Engine, text: String)? {
        // Score on the LANGUAGE-FAITHFUL engine. A Chinese-specialist (豆包)
        // transcribes English speech as Chinese homophones — its output reads as
        // ~100% CJK even for English, so it can't reveal that English was spoken.
        // The English slot (e.g. Soniox) renders English as Latin and Chinese as
        // Han, so it's the honest signal for language composition. Score it first;
        // the Chinese engine's text is the LAST scoring choice.
        let scoreOrder = dedup([englishEngine, mixedEngine, primary, chineseEngine])
        // For falling back to "any non-empty result" prefer the primary (HUD source).
        let fallbackOrder = dedup([primary, englishEngine, mixedEngine, chineseEngine])

        func firstNonEmpty(_ order: [Engine]) -> (Engine, String)? {
            for e in order {
                if let t = results[e], !t.isEmpty { return (e, t) }
            }
            return nil
        }

        guard let (_, scoreText) = firstNonEmpty(scoreOrder) else {
            return nil   // nothing transcribed
        }

        let chosen = slot(forScoreText: scoreText)
        if let t = results[chosen], !t.isEmpty {
            return (chosen, t)
        }
        // Chosen engine failed/absent — fall through to any non-empty result.
        return firstNonEmpty(fallbackOrder)
    }

    /// The engine whose transcript should decide the language — the
    /// language-faithful one (English slot, falling back to mixed, then Chinese).
    /// `MultiEngineBackend` uses this to know when it can route without waiting
    /// for the Chinese-specialist engine.
    var classifierEngine: Engine { englishEngine }

    private func dedup(_ engines: [Engine]) -> [Engine] {
        var seen = Set<Engine>()
        var out: [Engine] = []
        for e in engines where !seen.contains(e) {
            seen.insert(e)
            out.append(e)
        }
        return out
    }
}
