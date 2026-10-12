import Foundation
import ASRSupport

/// Qwen's auto-language metadata is repeated at encoder-window boundaries.
/// Work on cumulative snapshots: a header can straddle the confirmed/interim
/// split, and filtering those two strings independently would leak fragments.
internal enum QwenTranscriptFilter {
    static func partial(confirmed: String, provisional: String, suppressIncompleteTail: Bool) -> PartialTranscript {
        let combined = visibleText(confirmed + provisional, suppressIncompleteTail: suppressIncompleteTail)
        // Explicit mode keeps incomplete fragments visible in `combined`, but
        // they must remain interim until disambiguated, never a committed prefix.
        let candidate = visibleText(confirmed, suppressIncompleteTail: true)
        // A header completed by provisional text can invalidate the end of the
        // confirmed candidate. Only keep the common visible prefix confirmed;
        // boundary whitespace stays provisional until its right side is known.
        let prefix = String(zip(candidate, combined).prefix { $0 == $1 }.map { $0.0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PartialTranscript(finalText: prefix, interimText: String(combined.dropFirst(prefix.count)))
    }

    static func visibleText(_ text: String, suppressIncompleteTail: Bool) -> String {
        let keyword = "language"
        let marker = "<asr_text>"
        var visible = ""
        var cursor = text.startIndex
        var joiningRemovedBoundary = false

        func append(_ fragment: Substring) {
            let fragment = joiningRemovedBoundary ? fragment.drop(while: \.isWhitespace) : fragment
            guard !fragment.isEmpty else { return }
            if joiningRemovedBoundary, let left = visible.last, let right = fragment.first {
                // Reuse only the provider-neutral spacing rule at this removed
                // boundary; preserve ordinary text and meaningful Korean spaces.
                let boundary = TranscriptFormatter.tightenCJKSpaces("\(left) \(right)")
                // ASCII punctuation, ellipses and shared closing quotes also
                // join directly to Chinese/Japanese at an encoder-window boundary.
                let punctuationBeforeCJK = isHeaderBoundary(left)
                    && right.unicodeScalars.contains {
                        $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value)
                    }
                if boundary.contains(" "), !punctuationBeforeCJK { visible.append(" ") }
            }
            visible.append(contentsOf: fragment)
            joiningRemovedBoundary = false
        }

        while cursor < text.endIndex,
              let range = text.range(of: keyword, range: cursor..<text.endIndex) {
            append(text[cursor..<range.lowerBound])
            let atBoundary = range.lowerBound == text.startIndex
                || isHeaderBoundary(text[text.index(before: range.lowerBound)])
            let tail = text[range.upperBound...]
            if atBoundary, tail.first == " ", let end = tail.range(of: marker),
               plausibleLanguageName(tail[..<end.lowerBound]) {
                // Remove adjacent whitespace with the header, then restore at
                // most one separator when actual visible text arrives.
                while visible.last?.isWhitespace == true { visible.removeLast() }
                joiningRemovedBoundary = true
                cursor = end.upperBound
                continue
            }
            if atBoundary, suppressIncompleteTail, incompleteMetadata(tail, marker: marker) {
                return visible.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            append(text[range])
            cursor = range.upperBound
        }

        let remainder = text[cursor...]
        let wordStart = remainder.lastIndex(where: isHeaderBoundary).map { text.index(after: $0) } ?? cursor
        // The keyword itself may also arrive in pieces, including after an
        // earlier window. A non-prefix word (e.g. "lantern") stays untouched.
        if suppressIncompleteTail,
           wordStart == text.startIndex || isHeaderBoundary(text[text.index(before: wordStart)]) {
            let suffix = remainder[wordStart...]
            if !suffix.isEmpty, keyword.hasPrefix(suffix) {
                append(remainder[..<wordStart])
                return visible.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        append(remainder)
        return visible.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isHeaderBoundary(_ character: Character) -> Bool {
        if character.isWhitespace || ".,!?;:。，！？；：、…．｡､\"'>".contains(character) { return true }
        // Closing quotes/brackets may end a clause, but letters, digits and
        // word-internal punctuation (such as underscores) cannot start metadata.
        return character.unicodeScalars.allSatisfy {
            $0.properties.generalCategory == .closePunctuation || $0.properties.generalCategory == .finalPunctuation
        }
    }

    private static func plausibleLanguageName(_ value: Substring) -> Bool {
        let name = value.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 32,
              !name.lowercased().split(separator: " ").contains("language") else { return false }
        return name.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || $0 == 32 }
    }

    private static func incompleteMetadata(_ tail: Substring, marker: String) -> Bool {
        if tail.isEmpty { return true }
        guard tail.first == " " else { return false }
        if let markerStart = tail.firstIndex(of: "<") {
            return plausibleLanguageName(tail[..<markerStart]) && marker.hasPrefix(tail[markerStart...])
        }
        let name = tail.trimmingCharacters(in: .whitespaces).lowercased()
        // Without the reserved marker, an arbitrary short phrase is ordinary
        // speech, not metadata ("language model", "language is useful", etc.).
        return languageNames.contains { $0.hasPrefix(name) }
    }

    private static let languageNames = [
        "arabic", "cantonese", "chinese", "czech", "danish", "dutch", "english",
        "finnish", "french", "german", "greek", "hindi", "hungarian", "indonesian",
        "italian", "japanese", "korean", "macedonian", "malay", "persian", "polish",
        "portuguese", "romanian", "russian", "spanish", "swedish", "tagalog", "thai",
        "turkish", "vietnamese",
    ]
}
