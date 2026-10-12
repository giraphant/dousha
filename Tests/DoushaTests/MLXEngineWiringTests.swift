import XCTest
@testable import Dousha

final class MLXEngineWiringTests: XCTestCase {
    func test_localEngineRoundTripsWithDisplayName() {
        XCTAssertEqual(Engine.local.rawValue, "local")
        XCTAssertEqual(Engine(rawValue: "local"), .local)
        XCTAssertEqual(Engine.local.displayName, "本地 Qwen3")
        XCTAssertTrue(Engine.allCases.contains(.local))
    }

    func test_factoryMakesMLXBackend() {
        let backend = SpeechBackendFactory.make(engine: .local, language: "auto")
        XCTAssertTrue(backend is MLXBackend)
    }
}
