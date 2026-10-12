import Foundation
import ASRSupport

/// Only degenerate runs of five or more identical short units are shortened.
/// Ordinary reduplication (哈哈哈 / 很多很多) and separated repetitions survive.
/// This is a preview/fallback safeguard, never a transformation of batch output.
internal enum MLXPreviewRepetitionGuard {
    private static let runs = try! NSRegularExpression(
        pattern: #"([\p{L}\p{N}]{1,4}?)([\p{P}]?\s*)(?:\1\2){3,}\1(?:\2)?"#)

    static func collapse(_ text: String) -> String {
        let matches = runs.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let unit = Range(match.range(at: 1), in: result),
                  let separator = Range(match.range(at: 2), in: result) else { continue }
            let glue = String(result[separator])
            let trailing = !glue.isEmpty && result[range].hasSuffix(glue) ? glue : ""
            let replacement = Array(repeating: String(result[unit]), count: 4).joined(separator: glue) + trailing
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    static func partial(_ partial: PartialTranscript) -> PartialTranscript {
        let combined = collapse(partial.combined)
        let candidate = collapse(partial.finalText)
        let prefix = String(zip(candidate, combined).prefix { $0 == $1 }.map { $0.0 })
        return PartialTranscript(finalText: prefix, interimText: String(combined.dropFirst(prefix.count)))
    }
}
