import XCTest
import MLXASR
@testable import Dousha

final class EngineCatalogTests: XCTestCase {
    private func withPreferences(_ body: (Preferences, UserDefaults) -> Void) {
        let suite = "EngineCatalogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(Preferences(defaults: defaults), defaults)
    }

    func testLegacyLocalMigratesEveryRoutingSlotAndActiveEngine() {
        withPreferences { prefs, defaults in
            for key in ["chineseEngine", "englishEngine", "mixedEngine"] {
                defaults.set("local", forKey: key)
            }
            defaults.set(["local", "soniox"], forKey: "activeEngines")
            XCTAssertEqual(prefs.chineseEngine, .qwen3)
            XCTAssertEqual(prefs.englishEngine, .qwen3)
            XCTAssertEqual(prefs.mixedEngine, .qwen3)
            XCTAssertEqual(prefs.activeEngines, [.qwen3, .soniox])
            XCTAssertEqual(prefs.engine, .qwen3)
        }
    }

    func testMixedLegacyAndNewIDsAreDeduplicatedAndUnknownIDsIgnored() {
        withPreferences { prefs, defaults in
            defaults.set(["local", "qwen3", "unknown", "apple"], forKey: "activeEngines")
            XCTAssertEqual(prefs.activeEngines, [.qwen3, .apple])
            defaults.set("unknown", forKey: "chineseEngine")
            defaults.set(["unknown"], forKey: "activeEngines")
            XCTAssertEqual(prefs.chineseEngine, .apple)
            XCTAssertEqual(prefs.activeEngines, [.apple])
        }
    }

    func testSavingQwen3WritesCanonicalIDs() {
        withPreferences { prefs, defaults in
            prefs.setSingleEngine(.qwen3)
            for key in ["chineseEngine", "englishEngine", "mixedEngine"] {
                XCTAssertEqual(defaults.string(forKey: key), "qwen3")
            }
            XCTAssertEqual(defaults.stringArray(forKey: "activeEngines"), ["qwen3"])
        }
    }

    func testModelSelectionPersistsAndDefaultsUnknownValues() {
        withPreferences { prefs, defaults in
            XCTAssertEqual(prefs.qwen3Model, MLXModelCatalog.defaultModel)
            prefs.qwen3ModelRepoID = MLXModelCatalog.qwen3ASR_1_7B_8bit.repoID
            XCTAssertEqual(Preferences(defaults: defaults).qwen3Model, MLXModelCatalog.qwen3ASR_1_7B_8bit)
            defaults.set("retired/repo", forKey: "qwen3ModelRepoID")
            XCTAssertEqual(prefs.qwen3ModelRepoID, MLXModelCatalog.defaultModel.repoID)
            prefs.qwen3ModelRepoID = "invalid/repo"
            XCTAssertEqual(defaults.string(forKey: "qwen3ModelRepoID"), MLXModelCatalog.defaultModel.repoID)
        }
    }

    func testEngineMetadataKeepsIdentitySeparateFromLocality() {
        XCTAssertEqual(Engine.qwen3.displayName, "Qwen3")
        XCTAssertEqual(Engine.qwen3.kind, "MLX")
        XCTAssertEqual(Engine.qwen3.tags, ["本地", "实时"])
        XCTAssertEqual(Engine.apple.tags, ["本地", "内置", "实时"])
        XCTAssertFalse(Engine.soniox.isLocal)
        XCTAssertFalse(Engine.doubao.isLocal)
        XCTAssertEqual(Set(Engine.allCases.map(\.rawValue)).count, 4)
    }
}
