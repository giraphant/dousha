import XCTest
import MLXASR
import ConcurrencySupport
@testable import Dousha

final class MLXEngineWiringTests: XCTestCase {
    func test_qwen3EngineRoundTripsWithDisplayName() {
        XCTAssertEqual(Engine.qwen3.rawValue, "qwen3")
        XCTAssertEqual(Engine(rawValue: "qwen3"), .qwen3)
        XCTAssertEqual(Engine.qwen3.displayName, "Qwen3")
        XCTAssertTrue(Engine.allCases.contains(.qwen3))
    }

    func test_factoryMakesMLXBackend() {
        let backend = SpeechBackendFactory.make(engine: .qwen3, language: "auto")
        XCTAssertTrue(backend is MLXBackend)
    }

    @MainActor
    func test_beginSessionPassesLanguageIdentifierWithoutPremapping() async {
        let suite = "MLXEngineWiringTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let languages = Lock<[String?]>([])
        let backend = MLXBackend(preferences: preferences) { _, _, language in
            languages.withLock { $0.append(language) }
        }
        for identifier in ["zh-CN", "en-US", "auto"] {
            preferences.language = identifier
            await backend.beginSession(onPartial: { _ in }, onError: { _ in })
        }
        XCTAssertEqual(languages.value(), ["zh-CN", "en-US", "auto"])
        XCTAssertEqual(MLXASRSupport.qwenLanguage(forIdentifier: languages.value()[0]!), "Chinese")
        XCTAssertNil(MLXASRSupport.qwenLanguage(forIdentifier: "Chinese"),
                     "Passing an already-mapped Qwen3 name silently selects auto-detect")
    }
}
