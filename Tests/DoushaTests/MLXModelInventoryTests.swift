import XCTest
@testable import MLXASR

final class MLXModelInventoryTests: XCTestCase {
    private let model = MLXModelCatalog.defaultModel

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeModel(_ inventory: MLXModelInventory, model: MLXModelDescriptor) throws {
        let path = inventory.directory(for: model)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: path.appendingPathComponent("config.json"))
        try Data(repeating: 1, count: 128).write(to: path.appendingPathComponent("model.safetensors"))
    }

    func testCachePathMatchesPinnedMLXAudioLayout() throws {
        let root = try temporaryRoot().resolvingSymlinksInPath()
        let path = MLXModelInventory(cacheRoot: root).directory(for: model)
        XCTAssertEqual(path.path, root.appendingPathComponent("mlx-audio/mlx-community_Qwen3-ASR-0.6B-8bit").path)
    }

    func testDefaultRootUsesApplicationSupport() {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dousha/Models")
        XCTAssertEqual(MLXModelInventory().directory(for: model).path,
                       root.appendingPathComponent("mlx-audio/mlx-community_Qwen3-ASR-0.6B-8bit").path)
    }

    func testInventoryDistinguishesAbsentPartialAndCompleteCache() throws {
        let inventory = MLXModelInventory(cacheRoot: try temporaryRoot())
        XCTAssertFalse(inventory.entry(for: model).isInstalled)
        XCTAssertEqual(inventory.entry(for: model).bytesOnDisk, 0)
        let path = inventory.directory(for: model)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: path.appendingPathComponent("config.json"))
        try Data().write(to: path.appendingPathComponent("model.safetensors"))
        XCTAssertFalse(inventory.entry(for: model).isInstalled)
        try writeModel(inventory, model: model)
        XCTAssertTrue(inventory.entry(for: model).isInstalled)
        XCTAssertEqual(inventory.entry(for: model).bytesOnDisk, 130)
        try Data("invalid".utf8).write(to: path.appendingPathComponent("config.json"))
        XCTAssertFalse(inventory.entry(for: model).isInstalled)
    }

    func testUninstallDeletesOnlyTargetModelAndIsIdempotent() async throws {
        let root = try temporaryRoot()
        let inventory = MLXModelInventory(cacheRoot: root)
        let other = MLXModelCatalog.qwen3ASR_1_7B_8bit
        let hubDirectory = root.appendingPathComponent("models--mlx-community--Qwen3-ASR-0.6B-8bit")
        let otherHubDirectory = root.appendingPathComponent("models--mlx-community--Qwen3-ASR-1.7B-8bit")
        try FileManager.default.createDirectory(at: hubDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherHubDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: hubDirectory.appendingPathComponent("blob"))
        try writeModel(inventory, model: model)
        try writeModel(inventory, model: other)
        let store = MLXModelStore()
        try await inventory.uninstall(model, store: store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inventory.directory(for: model).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hubDirectory.path))
        XCTAssertTrue(inventory.entry(for: other).isInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherHubDirectory.path))
        try await inventory.uninstall(model, store: store)
    }

    func testMigrationMovesCatalogModelsAndPreservesLegacyHubAndUnrelatedModels() throws {
        let legacyRoot = try temporaryRoot()
        let legacy = MLXModelInventory(cacheRoot: legacyRoot)
        let inventory = MLXModelInventory(cacheRoot: try temporaryRoot())
        let unrelated = MLXModelDescriptor(repoID: "other/model", displayName: "Other")
        try writeModel(legacy, model: unrelated)
        let hubDirectory = legacyRoot.appendingPathComponent("models--mlx-community--Qwen3-ASR-0.6B-8bit")
        try FileManager.default.createDirectory(at: hubDirectory, withIntermediateDirectories: true)
        for model in MLXModelCatalog.all { try writeModel(legacy, model: model) }

        try inventory.migrateLegacyModels(from: legacyRoot)

        for model in MLXModelCatalog.all {
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.directory(for: model).path))
            XCTAssertTrue(inventory.entry(for: model).isInstalled)
            XCTAssertEqual(inventory.entry(for: model).bytesOnDisk, 130)
        }
        XCTAssertTrue(legacy.entry(for: unrelated).isInstalled)
        XCTAssertFalse(inventory.entry(for: unrelated).isInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hubDirectory.path))
    }

    func testMigrationLeavesExistingDestinationAndSourceUntouched() throws {
        let legacyRoot = try temporaryRoot()
        let legacy = MLXModelInventory(cacheRoot: legacyRoot)
        let inventory = MLXModelInventory(cacheRoot: try temporaryRoot())
        try writeModel(legacy, model: model)
        let destination = inventory.directory(for: model)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("keep")
        try Data([42]).write(to: marker)

        try inventory.migrateLegacyModels(from: legacyRoot)

        XCTAssertTrue(legacy.entry(for: model).isInstalled)
        XCTAssertEqual(try Data(contentsOf: marker), Data([42]))
        XCTAssertFalse(inventory.entry(for: model).isInstalled)
    }

    func testLoadedAndLoadingModelsCannotBeRemoved() {
        XCTAssertThrowsError(try MLXModelInventory.checkRemoval(model, state: .ready(repoID: model.repoID)))
        XCTAssertThrowsError(try MLXModelInventory.checkRemoval(model, state: .loading(repoID: model.repoID)))
        XCTAssertNoThrow(try MLXModelInventory.checkRemoval(model, state: .ready(repoID: "other/model")))
        XCTAssertNoThrow(try MLXModelInventory.checkRemoval(model, state: .failed(repoID: model.repoID, message: "offline")))
    }

    func testUninstallRefusesSymlinkAndPreservesItsTarget() async throws {
        let inventory = MLXModelInventory(cacheRoot: try temporaryRoot())
        let target = try temporaryRoot()
        let marker = target.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        let path = inventory.directory(for: model)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        do {
            try await inventory.uninstall(model, store: MLXModelStore())
            XCTFail("Symlinked model directories must not be removed")
        } catch MLXModelInventory.RemovalError.unsafePath {
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        }
    }
}
