import XCTest
@testable import Dousha

final class RecordingHistoryStoreTests: XCTestCase {
    private var dir: URL!
    private var store: RecordingHistoryStore!
    /// A fake "finished recording" source WAV the store copies from.
    private var sourceWAV: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-tests-\(UUID().uuidString)", isDirectory: true)
        store = RecordingHistoryStore(dir: dir)
        sourceWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent("src-\(UUID().uuidString).wav")
        // 44-byte header + 32000 bytes of samples = 1.0 s at 16 kHz mono s16.
        try Data(count: 44 + 32_000).write(to: sourceWAV)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: sourceWAV)
        super.tearDown()
    }

    func testSave_createsEntryWithSidecarAndDuration() throws {
        let id = store.save(wavFrom: sourceWAV, date: Date(timeIntervalSince1970: 1_700_000_000),
                            engine: "豆包", transcript: "你好", error: nil, limit: 5)
        XCTAssertNotNil(id)
        let entries = store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, id)
        XCTAssertEqual(entries[0].transcript, "你好")
        XCTAssertEqual(entries[0].engine, "豆包")
        XCTAssertNil(entries[0].error)
        XCTAssertEqual(entries[0].duration, 1.0, accuracy: 0.01)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.wavURL(id: id!).path))
    }

    func testSave_errorEntryKept() {
        let id = store.save(wavFrom: sourceWAV, date: Date(), engine: "豆包",
                            transcript: "", error: "network down", limit: 5)
        XCTAssertNotNil(id)
        XCTAssertEqual(store.entries().first?.error, "network down")
    }

    func testSave_prunesOldestBeyondLimit() {
        // Distinct dates → distinct ids (id embeds the timestamp to millisecond).
        for i in 0..<4 {
            _ = store.save(wavFrom: sourceWAV, date: Date(timeIntervalSince1970: 1_000 + Double(i)),
                           engine: "e", transcript: "t\(i)", error: nil, limit: 3)
        }
        let entries = store.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.transcript), ["t3", "t2", "t1"])  // newest first
    }

    func testNewest_returnsMostRecent() {
        _ = store.save(wavFrom: sourceWAV, date: Date(timeIntervalSince1970: 1_000),
                       engine: "e", transcript: "old", error: nil, limit: 5)
        _ = store.save(wavFrom: sourceWAV, date: Date(timeIntervalSince1970: 2_000),
                       engine: "e", transcript: "new", error: nil, limit: 5)
        XCTAssertEqual(store.newest()?.transcript, "new")
    }

    func testUpdateTranscript_rewritesSidecarAndClearsError() {
        let id = store.save(wavFrom: sourceWAV, date: Date(), engine: "e",
                            transcript: "", error: "boom", limit: 5)!
        store.updateTranscript(id: id, transcript: "重转成功")
        let entry = store.entries().first
        XCTAssertEqual(entry?.transcript, "重转成功")
        XCTAssertNil(entry?.error)
    }

    func testEntries_toleratesOrphanWavWithoutSidecar() throws {
        // Crash between the wav copy and the sidecar write leaves an orphan wav.
        let orphan = dir.appendingPathComponent("20260101-000000-000.wav")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 44 + 3_200).write(to: orphan)
        let entries = store.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].transcript, "")
        XCTAssertEqual(entries[0].duration, 0.1, accuracy: 0.01)
    }

    func testEntries_skipsMissingWav() {
        let id = store.save(wavFrom: sourceWAV, date: Date(), engine: "e",
                            transcript: "t", error: nil, limit: 5)!
        try? FileManager.default.removeItem(at: store.wavURL(id: id))  // simulate Caches cleanup
        XCTAssertTrue(store.entries().isEmpty)
    }

    func testRemove_deletesBothFiles() {
        let id = store.save(wavFrom: sourceWAV, date: Date(), engine: "e",
                            transcript: "t", error: nil, limit: 5)!
        store.remove(id: id)
        XCTAssertTrue(store.entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.wavURL(id: id).path))
    }

    func testSave_postsHistoryChanged() {
        let exp = expectation(forNotification: .doushaHistoryChanged, object: nil)
        _ = store.save(wavFrom: sourceWAV, date: Date(), engine: "e",
                       transcript: "t", error: nil, limit: 5)
        wait(for: [exp], timeout: 1)
    }
}
