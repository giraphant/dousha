import Foundation
import MLXAudioSTT
import MLX
import HuggingFace
import ConcurrencySupport

/// Offline seam for successful loads and prewarm without allocating MLX arrays.
/// Both operations require the process-wide lease and run off main.
internal protocol MLXLoadedModel: Sendable {
    func prepareSession(language: String?) -> MLXPreparedSession
    func prewarm() async throws
}

/// Safe to transfer after loading: only the process-wide lease holder accesses
/// the native model, including prewarm, streaming and the final full-audio pass.
/// MLXAudioSTT owns synchronization inside the streaming session (§4).
private final class QwenLoadedModel: MLXLoadedModel, @unchecked Sendable {
    let model: Qwen3ASRModel
    init(_ model: Qwen3ASRModel) { self.model = model }

    func prepareSession(language: String?) -> MLXPreparedSession {
        MLXPreparedSession(
            stream: StreamingInferenceSession(model: model, config: StreamingConfig(language: language)),
            finalPass: { request in
                let samples = MLXASRSupport.floatSamples(fromPCM16LE: request.pcm)
                guard !samples.isEmpty else { return "" }
                return self.model.generate(audio: MLXArray(samples), maxTokens: 8192,
                                           temperature: 0, context: request.context,
                                           language: request.language, chunkDuration: 1200,
                                           minChunkDuration: 1, repetitionPenalty: 1.15,
                                           repetitionContextSize: 32).text
            })
    }

    func prewarm() async throws {
        // One second of silence exercises encoder + decoder kernels. Bound the
        // token count so a silent-input hallucination cannot prolong startup.
        _ = model.generate(audio: MLXArray(Array(repeating: Float(0), count: 16_000)),
                           maxTokens: 8, temperature: 0, language: "Chinese",
                           repetitionPenalty: 1.15, repetitionContextSize: 32)
    }
}

/// A token can be released repeatedly, including after a cancelled acquire:
/// the gate only advances when the token is its current owner.
internal struct MLXSessionLease: Sendable {
    fileprivate let id: UUID
    fileprivate let gate: MLXSessionLeaseGate
    fileprivate let store: MLXModelStore?
    func release() async {
        if await gate.release(id) { await store?.didReleaseSessionLease() }
    }
}

/// Shared even by separately constructed stores: two engine instances must
/// never start competing sessions on the process's MLX runtime.
internal actor MLXSessionLeaseGate {
    static let shared = MLXSessionLeaseGate()
    private var owner: UUID?
    private var waiters: [(id: UUID, ready: OneShotChannel<Void>)] = []

    func acquire(store: MLXModelStore? = nil) async throws -> MLXSessionLease {
        try Task.checkCancellation()
        let id = UUID()
        if owner == nil {
            owner = id
        } else {
            let ready = OneShotChannel<Void>()
            waiters.append((id, ready))
            do {
                try await ready.wait()
                try Task.checkCancellation()
            } catch {
                // Also handles cancellation racing a successful hand-off.
                release(id)
                throw error
            }
        }
        return MLXSessionLease(id: id, gate: self, store: store)
    }

    @discardableResult
    fileprivate func release(_ id: UUID) -> Bool {
        guard owner == id else {
            waiters.removeAll { $0.id == id }
            return false
        }
        if waiters.isEmpty {
            owner = nil
        } else {
            let next = waiters.removeFirst()
            owner = next.id
            next.ready.finish(())
        }
        return true
    }
}

/// Process-wide owner of loaded MLX model weights. The shared instance survives
/// per-recording recognizers; model changes wait for the previous session lease.
public actor MLXModelStore {
    public static let shared = MLXModelStore()

    public enum State: Sendable, Equatable {
        case idle
        case loading(repoID: String)
        case ready(repoID: String)
        case failed(repoID: String, message: String)
    }

    public private(set) var state: State = .idle
    private var cached: (repoID: String, model: any MLXLoadedModel)?
    private var inFlight: (repoID: String, task: Task<any MLXLoadedModel, Error>)?
    private var warming: Set<String> = []
    // Includes requests waiting on another store's process-wide lease.
    private var leaseRequests = 0
    private var idleUnloadDelay: TimeInterval = 60
    private var idleUnloadTask: Task<Void, Never>?
    private let clearCache: @Sendable () -> Void
    private let loadModel: @Sendable (String) async throws -> any MLXLoadedModel

    public init() {
        clearCache = { Memory.clearCache() }
        loadModel = { repoID in
            try MLXModelInventory.legacyMigration.get()
            return QwenLoadedModel(try await Qwen3ASRModel.fromPretrained(repoID,
                cache: HubCache(cacheDirectory: MLXModelInventory.modelsDirectory)))
        }
        doushaLog("[MLXModelStore] state=idle")
    }

    /// Offline lifecycle/prewarm tests inject a loader and model operations
    /// that never touch Hugging Face or Metal. Production uses fromPretrained.
    internal init(clearCache: @escaping @Sendable () -> Void = {},
                  loadModel: @escaping @Sendable (String) async throws -> any MLXLoadedModel) {
        self.clearCache = clearCache
        self.loadModel = loadModel
        doushaLog("[MLXModelStore] state=idle")
    }

    /// Fire-and-forget preload (engine selected in the menu / app launch). Never throws.
    public nonisolated func warmup(_ model: MLXModelDescriptor) {
        Task { await self.preload(model) }
    }

    internal func acquireSessionLease() async throws -> MLXSessionLease {
        idleUnloadTask?.cancel()
        leaseRequests += 1
        do {
            return try await MLXSessionLeaseGate.shared.acquire(store: self)
        } catch {
            didReleaseSessionLease()
            throw error
        }
    }

    /// Applies to the next idle period; an active session keeps its lease.
    public func setIdleUnloadDelay(_ seconds: TimeInterval) {
        idleUnloadDelay = seconds
    }

    fileprivate func didReleaseSessionLease() {
        leaseRequests -= 1
        scheduleIdleUnload()
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        guard leaseRequests == 0, let repoID = cached?.repoID else { return }
        let delay = idleUnloadDelay
        idleUnloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                // Cache eviction also obeys the process-wide MLX lease.
                let lease = try await MLXSessionLeaseGate.shared.acquire()
                await self?.unloadIfIdle(repoID: repoID, delay: delay)
                await lease.release()
            } catch { } // Activity cancels the pending unload.
        }
    }

    private func unloadIfIdle(repoID: String, delay: TimeInterval) {
        guard !Task.isCancelled else { return }
        cached = nil
        state = .idle
        clearCache()
        doushaLog("[MLXModelStore] idleUnload repoID=\(repoID) idleSeconds=\(delay)")
    }

    /// Awaitable preload; warmup() wraps this for fire-and-forget callers.
    public func preload(_ descriptor: MLXModelDescriptor) async {
        idleUnloadTask?.cancel()
        defer { scheduleIdleUnload() }
        if cached?.repoID == descriptor.repoID { return }
        // Coalesce warmups even while they are waiting for another session's
        // lease, including a failed load (no queue of identical retry loads).
        guard warming.insert(descriptor.repoID).inserted else { return }
        defer { warming.remove(descriptor.repoID) }
        // A warmup during an identical load joins it without queueing another
        // lease. The load owner alone publishes its terminal state.
        if let inFlight, inFlight.repoID == descriptor.repoID {
            _ = try? await inFlight.task.value
            return
        }
        do {
            let lease = try await acquireSessionLease()
            do {
                // Recheck after waiting: a recording may have loaded this model
                // first. Never add prewarm to a recording-triggered load.
                if cached?.repoID != descriptor.repoID {
                    let model = try await load(descriptor, lease: lease)
                    await Task.detached(priority: .userInitiated) {
                        let started = ProcessInfo.processInfo.systemUptime
                        do {
                            try await model.prewarm()
                        } catch {
                            // Weights remain usable; prewarm is only an optimization.
                            doushaLog("[MLXModelStore] prewarmFailed repoID=\(descriptor.repoID) error=\(error.localizedDescription)")
                        }
                        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                        doushaLog("[MLXModelStore] prewarm repoID=\(descriptor.repoID) ms=\(milliseconds)")
                    }.value
                }
            } catch {
                // load() publishes and logs the error; warmup never emits an
                // engine error or changes an active recording's callbacks.
            }
            await lease.release()
        } catch {
            doushaLog("[MLXModelStore] warmup cancelled repoID=\(descriptor.repoID)")
        }
    }

    /// Only a lease holder may replace the cache or create an inference session.
    /// Keeping the lease throughout loading prevents a model switch while the
    /// old session is still draining or running its final batch pass. A cancelled caller does not cancel the
    /// shared download; its setup path releases the lease after the load settles.
    internal func load(_ descriptor: MLXModelDescriptor, lease: MLXSessionLease) async throws -> any MLXLoadedModel {
        if let cached, cached.repoID == descriptor.repoID { return cached.model }
        if let inFlight, inFlight.repoID == descriptor.repoID {
            return try await inFlight.task.value
        }

        cached = nil
        let started = Date()
        state = .loading(repoID: descriptor.repoID)
        doushaLog("[MLXModelStore] state=loading repoID=\(descriptor.repoID)")
        let loadModel = self.loadModel
        let task = Task.detached(priority: .userInitiated) {
            try await loadModel(descriptor.repoID)
        }
        inFlight = (descriptor.repoID, task)
        do {
            let model = try await task.value
            cached = (descriptor.repoID, model)
            inFlight = nil
            state = .ready(repoID: descriptor.repoID)
            doushaLog("[MLXModelStore] state=ready repoID=\(descriptor.repoID) loadMs=\(Int(Date().timeIntervalSince(started) * 1000))")
            return model
        } catch {
            inFlight = nil
            state = .failed(repoID: descriptor.repoID, message: error.localizedDescription)
            doushaLog("[MLXModelStore] state=failed repoID=\(descriptor.repoID) loadMs=\(Int(Date().timeIntervalSince(started) * 1000)) error=\(error.localizedDescription)")
            throw error
        }
    }
}
