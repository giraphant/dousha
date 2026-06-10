import Foundation

/// Parsing / formatting for the free-text 个性词库 editor. Terms are separated by
/// 顿号 / 中英文逗号 / 分号 / 换行 — never spaces, so multi-word terms like
/// "machine learning" survive intact.
enum GlossaryText {
    private static let separators = CharacterSet(charactersIn: "、，,；;\n\r")

    /// Split editor text into normalised terms: trimmed, no empties,
    /// de-duplicated preserving first-seen order.
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for piece in text.components(separatedBy: separators) {
            let term = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term).inserted else { continue }
            result.append(term)
        }
        return result
    }

    /// Canonical display form: terms joined by 顿号.
    static func format(_ terms: [String]) -> String {
        terms.joined(separator: "、")
    }
}
