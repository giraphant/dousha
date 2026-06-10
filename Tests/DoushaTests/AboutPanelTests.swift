import XCTest
@testable import Dousha

final class AboutPanelTests: XCTestCase {
    func testApplicationVersionUsesBundleShortVersionFromBundleInfo() throws {
        let bundle = try makeBundle(info: [
            "CFBundleShortVersionString": "9.8.7",
            "CFBundleVersion": "123"
        ])

        XCTAssertEqual(AboutPanel.applicationVersion(bundle: bundle), "9.8.7")
    }

    func testApplicationVersionFallsBackToBuildVersion() throws {
        let bundle = try makeBundle(info: [
            "CFBundleVersion": "123"
        ])

        XCTAssertEqual(AboutPanel.applicationVersion(bundle: bundle), "123")
    }

    private func makeBundle(info: [String: String], file: StaticString = #filePath, line: UInt = #line) throws -> Bundle {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plistURL = directory.appendingPathComponent("Info.plist")
        try (info as NSDictionary).write(to: plistURL)
        return try XCTUnwrap(Bundle(url: directory), file: file, line: line)
    }
}
