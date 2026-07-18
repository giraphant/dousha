import Foundation
import DoubaoASR

public enum DoubaoSmokeResultComparator {
    public struct SummaryEntry: Sendable {
        public var fixture: String
        public var profile: String
        public var transcript: String
        public var diagnostics: String

        public init(fixture: String, profile: String, transcript: String, diagnostics: String) {
            self.fixture = fixture
            self.profile = profile
            self.transcript = transcript
            self.diagnostics = diagnostics
        }
    }

    public struct Comparison: Sendable {
        public var fixture: String
        public var profile: String
        public var exactMatch: Bool
        public var normalizedMatch: Bool
        public var candidateEmpty: Bool
        public var lengthDelta: Int
        public var commonPrefixLength: Int
        public var similarity: Double
        public var diagnostics: String
    }

    public static func compare(entries: [SummaryEntry], officialProfile: String = DoubaoExperimentProfile.official.rawValue) -> [Comparison] {
        let officials = Dictionary(uniqueKeysWithValues: entries.filter { $0.profile == officialProfile }.map { ($0.fixture, $0) })
        return entries
            .filter { $0.profile != officialProfile }
            .compactMap { candidate in
                guard let official = officials[candidate.fixture] else { return nil }
                return compare(official: official, candidate: candidate)
            }
            .sorted { lhs, rhs in
                if lhs.fixture != rhs.fixture { return lhs.fixture < rhs.fixture }
                return lhs.profile < rhs.profile
            }
    }

    public static func compare(official: SummaryEntry, candidate: SummaryEntry) -> Comparison {
        let officialTranscript = official.transcript
        let candidateTranscript = candidate.transcript
        let normalizedOfficial = normalize(officialTranscript)
        let normalizedCandidate = normalize(candidateTranscript)
        let commonPrefix = commonPrefixLength(officialTranscript, candidateTranscript)
        let distance = editDistance(Array(officialTranscript), Array(candidateTranscript))
        let maxLength = max(officialTranscript.count, candidateTranscript.count)
        let similarity = maxLength == 0 ? 1.0 : max(0.0, 1.0 - Double(distance) / Double(maxLength))

        return Comparison(
            fixture: candidate.fixture,
            profile: candidate.profile,
            exactMatch: officialTranscript == candidateTranscript,
            normalizedMatch: normalizedOfficial == normalizedCandidate,
            candidateEmpty: candidateTranscript.isEmpty,
            lengthDelta: candidateTranscript.count - officialTranscript.count,
            commonPrefixLength: commonPrefix,
            similarity: similarity,
            diagnostics: candidate.diagnostics
        )
    }

    public static func loadSummary(path: String) throws -> [SummaryEntry] {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let value = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return value.compactMap { item in
            guard let fixture = item["fixture"] as? String,
                  let profile = item["profile"] as? String else { return nil }
            return SummaryEntry(
                fixture: fixture,
                profile: profile,
                transcript: item["transcript"] as? String ?? "",
                diagnostics: item["diagnostics"] as? String ?? ""
            )
        }
    }

    public static func summaryPath(for argument: String) -> String {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: argument, isDirectory: &isDirectory), isDirectory.boolValue {
            return URL(fileURLWithPath: argument).appendingPathComponent("summary.json").path
        }
        return argument
    }

    public static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        for (a, b) in zip(lhs, rhs) {
            guard a == b else { break }
            count += 1
        }
        return count
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0...rhs.count)
        var current = Array(repeating: 0, count: rhs.count + 1)

        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                if lhs[i - 1] == rhs[j - 1] {
                    current[j] = previous[j - 1]
                } else {
                    current[j] = min(previous[j], current[j - 1], previous[j - 1]) + 1
                }
            }
            swap(&previous, &current)
        }

        return previous[rhs.count]
    }
}
