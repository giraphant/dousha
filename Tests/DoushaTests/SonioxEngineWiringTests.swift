import XCTest
@testable import Dousha

final class SonioxEngineWiringTests: XCTestCase {
    func test_engineAllCasesIncludesSoniox() {
        XCTAssertTrue(Engine.allCases.contains(.soniox))
    }

    func test_sonioxDisplayName() {
        XCTAssertEqual(Engine.soniox.displayName, "Soniox")
    }

    func test_sonioxRawValueRoundTrips() {
        XCTAssertEqual(Engine(rawValue: "soniox"), .soniox)
    }

    func test_factoryMakesSonioxBackend() {
        let backend = SpeechBackendFactory.make(engine: .soniox, language: "auto")
        XCTAssertTrue(backend is SonioxBackend)
    }

}
