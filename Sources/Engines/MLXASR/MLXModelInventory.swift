import Foundation
import ConcurrencySupport

/// Disk inventory only; this never downloads or initializes the MLX runtime.
public struct MLXModelInventory: Sendable {
    public static let modelsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Dousha/Models", isDirectory: true)

    /// Shared by loading and settings; Swift runs this migration once per process.
    public static let legacyMigration = Result {
        try MLXModelInventory().migrateLegacyModels(from: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true))
    }

    public struct Entry: Sendable, Equatable {
        public let isInstalled: Bool
        /// Sum of cached file sizes, including incomplete downloads.
        public let bytesOnDisk: Int64
    }

    public enum RemovalError: LocalizedError {
        case modelInUse
        case unsafePath

        public var errorDescription: String? {
            switch self {
            case .modelInUse:
                return "此模型仍已加载。请先使用另一个模型并等待加载完成，或退出并重新打开豆沙后卸载。"
            case .unsafePath:
                return "模型缓存路径无效，无法卸载。"
            }
        }
    }

    private let cacheRoot: URL

    public init(cacheRoot: URL = MLXModelInventory.modelsDirectory) {
        self.cacheRoot = cacheRoot.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Coupled to mlx-audio-swift 244458d7 ModelUtils.resolveOrDownloadModel:
    /// it has no public path-only helper. Mirror its mlx-audio/<org>_<repo>
    /// suffix under our app-owned HubCache root.
    public func directory(for model: MLXModelDescriptor) -> URL {
        cacheRoot.appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(model.repoID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    internal func migrateLegacyModels(from legacyRoot: URL) throws {
        let legacy = MLXModelInventory(cacheRoot: legacyRoot)
        let manager = FileManager.default
        try manager.createDirectory(at: cacheRoot.appendingPathComponent("mlx-audio", isDirectory: true),
                                    withIntermediateDirectories: true)
        for model in MLXModelCatalog.all {
            let source = legacy.directory(for: model)
            let destination = directory(for: model)
            if manager.fileExists(atPath: source.path), !manager.fileExists(atPath: destination.path) {
                try manager.moveItem(at: source, to: destination)
                doushaLog("[MLXModelStore] migrated repoID=\(model.repoID) from=\(source.path)")
            }
        }
    }

    public func entry(for model: MLXModelDescriptor) -> Entry {
        let directory = directory(for: model)
        let manager = FileManager.default
        // Match the upstream cache-hit test: valid JSON + nonempty safetensors.
        // "Installed" describes cached files, not an inference health check.
        let files = (try? manager.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let hasWeights = files.contains {
            $0.pathExtension == "safetensors" &&
                ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }
        let config = try? Data(contentsOf: directory.appendingPathComponent("config.json"))
        let hasConfig = config.flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil
        var bytes: Int64 = 0
        if let enumerator = manager.enumerator(at: directory,
                                              includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let file as URL in enumerator {
                if let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                   values.isRegularFile == true {
                    bytes += Int64(values.fileSize ?? 0)
                }
            }
        }
        return Entry(isInstalled: hasWeights && hasConfig, bytesOnDisk: bytes)
    }

    /// Serialize deletion with downloads and complete inference sessions. Refuse
    /// every loaded model (even if selection has since changed): state=ready is
    /// the store's cached model, whose mapped weights must remain intact.
    public func uninstall(_ model: MLXModelDescriptor, store: MLXModelStore = .shared) async throws {
        let lease = try await store.acquireSessionLease()
        do {
            try Task.checkCancellation()
            try Self.checkRemoval(model, state: await store.state)
            let hubDirectory = cacheRoot.appendingPathComponent("models--" + model.repoID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
            let directories = [(directory(for: model), cacheRoot.appendingPathComponent("mlx-audio", isDirectory: true)),
                               (hubDirectory, cacheRoot)]
            for (directory, parent) in directories {
                guard directory.standardizedFileURL.deletingLastPathComponent().path == parent.path,
                      directory.resolvingSymlinksInPath().path == directory.path else {
                    throw RemovalError.unsafePath
                }
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
            }
            await lease.release()
        } catch {
            await lease.release()
            throw error
        }
    }

    internal static func checkRemoval(_ model: MLXModelDescriptor, state: MLXModelStore.State) throws {
        switch state {
        case .ready(let repoID), .loading(let repoID):
            if repoID == model.repoID { throw RemovalError.modelInUse }
        default:
            break
        }
    }
}
