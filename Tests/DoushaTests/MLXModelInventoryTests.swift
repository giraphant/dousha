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
        let inventory = MLXModelInventory(cacheRoot: try temporaryRoot())
        let other = MLXModelCatalog.qwen3ASR_1_7B_8bit
        try writeModel(inventory, model: model)
        try writeModel(inventory, model: other)
        let store = MLXModelStore()
        try await inventory.uninstall(model, store: store)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inventory.directory(for: model).path))
        XCTAssertTrue(inventory.entry(for: other).isInstalled)
        try await inventory.uninstall(model, store: store)
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
