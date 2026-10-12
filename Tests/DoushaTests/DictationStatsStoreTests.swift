import XCTest
@testable import Dousha

final class DictationStatsStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    func testPersistsCountsAndAggregatesWithoutText() throws {
        let url = dir.appendingPathComponent("stats.json")
        let store = DictationStatsStore(url: url)
        let text = "你 好\n e\u{301} 👩🏽‍💻\t"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        store.record(text: text, audioSeconds: 60, bundleID: "app.one", appName: "One", date: date)
        // A second instance must merge with the first instance's saved counts.
        DictationStatsStore(url: url).record(text: "AB", audioSeconds: 30,
                                           bundleID: "app.one", appName: "Renamed", date: date)
        let stats = store.load()
        XCTAssertEqual(stats.totals.dictations, 2)
        XCTAssertEqual(stats.totals.audioSeconds, 90)
        XCTAssertEqual(stats.totals.characters, 6)
        XCTAssertEqual(stats.charactersPerMinute, 4)
        XCTAssertEqual(stats.days.count, 1)
        XCTAssertEqual(stats.days[0].counts.characters, 6)
        XCTAssertEqual(stats.days[0].counts.audioSeconds, 90)
        XCTAssertEqual(stats.days[0].counts.dictations, 2)
        XCTAssertEqual(stats.apps["app.one"]?.name, "Renamed")
        XCTAssertEqual(stats.apps["app.one"]?.dictations, 2)
        XCTAssertEqual(stats.apps["app.one"]?.characters, 6)
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(json.contains("你"))
        XCTAssertFalse(json.contains("AB"))
    }

    @MainActor
    func testKeepsThirtyDaysAndFillsSevenDayTrendAcrossDST() {
        let store = DictationStatsStore(url: dir.appendingPathComponent("stats.json"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28))!
        for offset in [-30, -29, -6, -2, 0] {
            store.record(text: "字", audioSeconds: 10, bundleID: nil, appName: "",
                         date: calendar.date(byAdding: .day, value: offset, to: today)!, calendar: calendar)
        }
        let stats = store.load()
        XCTAssertEqual(stats.totals.dictations, 5)
        XCTAssertEqual(stats.days.count, 4)
        XCTAssertEqual(stats.days.first?.date, calendar.date(byAdding: .day, value: -29, to: today))
        XCTAssertEqual(stats.recentDays(endingAt: today, calendar: calendar).map(\.counts.characters),
                       [1, 0, 0, 0, 1, 0, 1])
        XCTAssertTrue(stats.apps.isEmpty)
    }

    @MainActor
    func testEmptyTextIsIgnoredAndResetClearsAllAggregates() {
        let store = DictationStatsStore(url: dir.appendingPathComponent("stats.json"))
        XCTAssertEqual(store.load().charactersPerMinute, 0)
        for text in ["", " \n\t\u{3000}"] {
            store.record(text: text, audioSeconds: 5, bundleID: "app.one", appName: "One")
        }
        XCTAssertEqual(store.load().totals.dictations, 0)
        store.record(text: "字", audioSeconds: 5, bundleID: "app.one", appName: "One")
        store.reset()
        let stats = store.load()
        XCTAssertEqual(stats.totals.dictations, 0)
        XCTAssertEqual(stats.totals.audioSeconds, 0)
        XCTAssertEqual(stats.totals.characters, 0)
        XCTAssertTrue(stats.days.isEmpty)
        XCTAssertTrue(stats.apps.isEmpty)
    }
}
