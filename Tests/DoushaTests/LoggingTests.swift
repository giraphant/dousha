import XCTest
@testable import ConcurrencySupport

final class LoggingTests: XCTestCase {
    func testDisabledLogSkipsWritesAndCanBeReenabled() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DoushaFileLog(fileURL: directory.appendingPathComponent("dousha.log"))

        log.setEnabled(false)
        log.append("disabled before opening")
        log.setEnabled(false) // Drain the append queue before reading the filesystem.
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        log.setEnabled(true)
        log.append("enabled first")
        log.setEnabled(false)
        let before = try Data(contentsOf: log.fileURL)
        log.append("disabled after opening")
        log.setEnabled(false)
        XCTAssertEqual(try Data(contentsOf: log.fileURL), before)

        log.setEnabled(true)
        log.append("enabled again")
        log.setEnabled(false)
        let contents = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("enabled first"))
        XCTAssertTrue(contents.contains("enabled again"))
    }

    func testDeleteRemovesBothLogsAndNextAppendReopensFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = DoushaFileLog(fileURL: directory.appendingPathComponent("dousha.log"))
        log.append("before deletion")
        log.setEnabled(true) // Drain the append queue before creating the rotated sibling.
        let rotated = log.fileURL.appendingPathExtension("1")
        try Data("old log".utf8).write(to: rotated)

        try log.deleteLogs()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotated.path))

        log.append("after deletion")
        log.setEnabled(false)
        let contents = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("after deletion"))
        XCTAssertFalse(contents.contains("before deletion"))
    }
}
