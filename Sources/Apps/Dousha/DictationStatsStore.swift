import Foundation

struct DictationStats: Codable {
    struct Counts: Codable {
        var dictations = 0
        var audioSeconds: TimeInterval = 0
        var characters = 0

        mutating func add(audioSeconds: TimeInterval, characters: Int) {
            dictations += 1
            self.audioSeconds += audioSeconds
            self.characters += characters
        }
    }

    struct Day: Codable, Identifiable {
        var date: Date
        var counts = Counts()
        var id: Date { date }
    }

    struct App: Codable {
        var name: String
        var dictations = 0
        var characters = 0
    }

    var totals = Counts()
    var days: [Day] = []
    var apps: [String: App] = [:]

    var charactersPerMinute: Double {
        totals.audioSeconds > 0 ? Double(totals.characters) * 60 / totals.audioSeconds : 0
    }

    func recentDays(endingAt date: Date = Date(), calendar: Calendar = .current) -> [Day] {
        let today = calendar.startOfDay(for: date)
        return (-6...0).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            return days.first { calendar.isDate($0.date, inSameDayAs: day) } ?? Day(date: day)
        }
    }
}

extension Notification.Name {
    static let doushaStatsChanged = Notification.Name("DoushaStatsChanged")
}

/// Counts only; read-modify-write keeps the app and Settings' store instances in sync.
@MainActor
struct DictationStatsStore {
    let url: URL

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Dousha/stats.json")) {
        self.url = url
    }

    func load() -> DictationStats {
        guard let data = try? Data(contentsOf: url),
              let stats = try? JSONDecoder().decode(DictationStats.self, from: data) else {
            return DictationStats()
        }
        return stats
    }

    func record(text: String, audioSeconds: TimeInterval, bundleID: String?, appName: String,
                date: Date = Date(), calendar: Calendar = .current) {
        let characters = text.filter { !$0.isWhitespace }.count
        guard characters > 0 else { return }
        var stats = load()
        stats.totals.add(audioSeconds: audioSeconds, characters: characters)
        let today = calendar.startOfDay(for: date)
        let cutoff = calendar.date(byAdding: .day, value: -29, to: today)!
        stats.days.removeAll { $0.date < cutoff }
        if let index = stats.days.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: today) }) {
            stats.days[index].counts.add(audioSeconds: audioSeconds, characters: characters)
        } else {
            stats.days.append(.init(date: today, counts: .init(dictations: 1, audioSeconds: audioSeconds,
                                                             characters: characters)))
        }
        if let bundleID {
            var app = stats.apps[bundleID] ?? .init(name: appName)
            app.name = appName
            app.dictations += 1
            app.characters += characters
            stats.apps[bundleID] = app
        }
        write(stats)
    }

    func reset() { write(DictationStats()) }

    private func write(_ stats: DictationStats) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(stats) {
            try? data.write(to: url, options: .atomic)
        }
        NotificationCenter.default.post(name: .doushaStatsChanged, object: nil)
    }
}
