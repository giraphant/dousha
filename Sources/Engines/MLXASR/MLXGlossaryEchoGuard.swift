import Foundation

/// Detects and resolves Qwen3-ASR system-prompt glossary hallucinations on silent
/// or ambient-noise audio (e.g. echoing `"Vocabulary:\n- quasi\n- 吉登斯…"` as
/// `"词汇：quasi，吉登斯，非人，能动性。"` or outputting a lone glossary term).
///
/// Strategy:
///   1. Normal dictations (which contain non-glossary words and no vocabulary
///      header) classify as `.normal` with zero extra inference cost.
///   2. Outputs that echo a vocabulary prompt header (`.promptLeakage`), consist
///      solely of glossary terms (`.glossaryOnly`), or inject glossary terms far
///      beyond what the context-free streaming pass heard trigger a single
///      unbiased verification pass (`context: ""`).
///   3. If the unbiased pass hears no real speech (or only a stray filler char),
///      the biased output is confirmed as a prompt hallucination and suppressed.
///      If the user genuinely spoke a glossary term ("吉登斯"), the unbiased pass
///      still hears comparable speech ("基登斯"), confirming it and keeping the
///      glossary-corrected spelling.
internal enum MLXGlossaryEchoGuard {
    enum Classification: Equatable, Sendable {
        case normal
        case promptLeakage
        case glossaryOnly(matchedTermCount: Int)
    }

    private static let promptHeaderPrefixes: [String] = [
        "vocabulary:", "vocabulary：", "vocabulary ", "vocabulary\n",
        "词汇表：", "词汇表:", "词汇表 ", "词汇表，",
        "专业词汇：", "专业词汇:",
        "常用词汇：", "常用词汇:",
        "关键词：", "关键词:",
        "词表：", "词表:",
        "词汇：", "词汇:", "词汇 ", "词汇，", "词汇,", "词汇\n",
        "词库：", "词库:",
        "热词：", "热词:",
        "术语：", "术语:",
        "terms:", "terms：",
        "glossary:", "glossary：",
    ]

    private static let listLinePrefixes: [Character] = ["-", "•", "·", "*"]

    private static let termSeparators = CharacterSet(charactersIn: "\n\r、，,；;")

    /// Extract individual glossary terms from a Qwen3 system context string
    /// (supports both `"Vocabulary:\n- a\n- b"` and plain separated term lists).
    static func extractTerms(from context: String) -> [String] {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var body = stripLeadingHeader(from: trimmed).text
        if body.isEmpty { body = trimmed }

        var seen = Set<String>()
        var terms: [String] = []
        for rawPiece in body.components(separatedBy: termSeparators) {
            var piece = rawPiece.trimmingCharacters(in: .whitespacesAndNewlines)
            while let first = piece.first, listLinePrefixes.contains(first) {
                piece = String(piece.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !piece.isEmpty else { continue }
            let key = piece.lowercased()
            guard seen.insert(key).inserted else { continue }
            terms.append(piece)
        }
        return terms
    }

    /// Strips whitespace, punctuation, and symbols to leave only substantive
    /// spoken characters (letters, ideographs, digits).
    static func coreText(_ text: String) -> String {
        let filtered = text.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(filtered))
    }

    /// True when the text contains at least one non-punctuation, non-whitespace
    /// character (so stray `"。"` / `"..."` from streaming counts as empty).
    static func hasSubstantiveText(_ text: String) -> Bool {
        !coreText(text).isEmpty
    }

    /// Classify whether `batchText` looks like a system-prompt glossary echo.
    static func classify(batchText: String, context: String) -> Classification {
        let terms = extractTerms(from: context)
        guard !terms.isEmpty else { return .normal }
        let trimmed = batchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .normal }

        let stripped = stripLeadingHeader(from: trimmed)
        let bulletList = looksLikeBulletList(stripped.text)
        let (matchedCount, residual) = removeGlossaryTerms(terms, from: stripped.text)
        guard matchedCount > 0 else { return .normal }

        let residualCore = coreText(residual)
        if stripped.hadHeader || bulletList {
            // Prompt header ("词汇：", "Vocabulary:") or bullet list ("- a\n- b")
            // combined with glossary terms is a direct prompt echo.
            if residualCore.count <= 2 || matchedCount >= 2 {
                return .promptLeakage
            }
        }

        if residualCore.isEmpty {
            return .glossaryOnly(matchedTermCount: matchedCount)
        }
        // Multiple glossary terms joined by a single connector/filler char
        // (e.g. "吉登斯和福柯", "嗯，quasi，吉登斯，非人，能动性").
        if matchedCount >= 2 && residualCore.count <= 2 {
            return .glossaryOnly(matchedTermCount: matchedCount)
        }
        return .normal
    }

    /// Whether `batchText` should be cross-checked with a context-free batch pass.
    static func needsUnbiasedVerification(
        batchText: String,
        streamFallback: String,
        context: String
    ) -> (verify: Bool, classification: Classification) {
        let classification = classify(batchText: batchText, context: context)
        switch classification {
        case .promptLeakage, .glossaryOnly:
            return (true, classification)
        case .normal:
            let terms = extractTerms(from: context)
            guard !terms.isEmpty else { return (false, .normal) }
            let streamCoreCount = coreText(streamFallback).count
            let batchCoreCount = coreText(batchText).count
            // If streaming heard almost nothing (≤ 2 chars, e.g. stray "嗯" on
            // ambient noise) yet batch expanded into much longer text containing
            // glossary terms, verify without context.
            if streamCoreCount <= 2, batchCoreCount > max(3, streamCoreCount * 2) {
                let (matchedCount, _) = removeGlossaryTerms(terms, from: batchText)
                if matchedCount > 0 {
                    return (true, .normal)
                }
            }
            return (false, .normal)
        }
    }

    /// Resolve a suspect biased batch output using the context-free verification
    /// output. Returns `(text, suppressedHallucination)`: when
    /// `suppressedHallucination` is true, callers must deliver `""` and must NOT
    /// fall back to noisy streaming text.
    static func resolve(
        biasedBatch: String,
        unbiasedBatch: String?,
        streamFallback: String,
        classification: Classification
    ) -> (text: String, suppressedHallucination: Bool) {
        let biasedCoreCount = coreText(biasedBatch).count
        let streamCoreCount = coreText(streamFallback).count

        guard let unbiased = unbiasedBatch else {
            // Verification pass timed out or failed.
            switch classification {
            case .promptLeakage:
                return ("", true)
            case .glossaryOnly, .normal:
                // Keep biased output only if streaming already heard comparable speech.
                if streamCoreCount >= 2 && streamCoreCount * 2 >= biasedCoreCount {
                    return (biasedBatch, false)
                }
                return ("", true)
            }
        }

        let unbiasedCore = coreText(unbiased)
        // Unbiased pass heard nothing at all → confirmed glossary hallucination.
        if unbiasedCore.isEmpty {
            return ("", true)
        }

        // Unbiased pass heard far less than the biased glossary dump (e.g. a
        // 1-2 char ambient filler "嗯"/"嗯嗯" vs a 12-char glossary list).
        if unbiasedCore.count * 2 < biasedCoreCount {
            if unbiasedCore.count <= 1
                || (classification == .promptLeakage && unbiasedCore.count <= 2 && unbiasedCore.count * 3 < biasedCoreCount) {
                return ("", true)
            }
            return (unbiased, false)
        }

        // Never emit a leaked prompt header ("词汇：..." / "Vocabulary: ...")
        // even when real speech was present; prefer the clean unbiased transcript.
        if classification == .promptLeakage {
            return (unbiased, false)
        }

        // Real speech corroborated by the unbiased pass: keep the glossary-biased
        // spelling (e.g. unbiased "基登斯" corroborates biased "吉登斯").
        return (biasedBatch, false)
    }

    // MARK: - Helpers

    private static func stripLeadingHeader(from text: String) -> (hadHeader: Bool, text: String) {
        let lower = text.lowercased()
        for prefix in promptHeaderPrefixes where lower.hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (true, rest)
        }
        return (false, text)
    }

    private static func looksLikeBulletList(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        let bulleted = lines.filter { line in
            guard let first = line.first else { return false }
            return listLinePrefixes.contains(first)
        }
        return bulleted.count == lines.count && (lines.count >= 2 || lines[0].hasPrefix("- "))
    }

    /// Removes all occurrences of glossary terms (longest-first, case-insensitive)
    /// and returns `(matchedCount, residualText)`.
    private static func removeGlossaryTerms(_ terms: [String], from text: String) -> (Int, String) {
        let sortedTerms = terms.sorted { $0.count > $1.count }
        var remaining = text
        var matched = 0

        for term in sortedTerms {
            var searchStart = remaining.startIndex
            var next = ""
            var termHits = 0
            while searchStart < remaining.endIndex,
                  let range = remaining.range(of: term, options: [.caseInsensitive],
                                              range: searchStart..<remaining.endIndex) {
                next.append(contentsOf: remaining[searchStart..<range.lowerBound])
                next.append(" ")
                searchStart = range.upperBound
                termHits += 1
            }
            if termHits > 0 {
                next.append(contentsOf: remaining[searchStart...])
                remaining = next
                matched += termHits
            }
        }
        return (matched, remaining)
    }
}
