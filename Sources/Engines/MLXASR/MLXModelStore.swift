import Foundation
import MLXAudioSTT
import ConcurrencySupport

/// Safe to transfer after loading: the store never mutates the published model,
/// and only the holder of the process-wide lease creates a streaming session
/// or runs its subsequent full-audio batch pass using it. MLXAudioSTT owns
/// synchronization inside the streaming session. Do not expose
/// the model to callers that bypass the lease (ARCHITECTURE §4).
internal final class MLXLoadedModel: @unchecked Sendable {
    let model: Qwen3ASRModel
    init(_ model: Qwen3ASRModel) { self.model = model }
}

/// A token can be released repeatedly, including after a cancelled acquire:
/// the gate only advances when the token is its current owner.
internal struct MLXSessionLease: Sendable {
    fileprivate let id: UUID
    fileprivate let gate: MLXSessionLeaseGate
    func release() async { await gate.release(id) }
}

/// Shared even by separately constructed stores: two engine instances must
/// never start competing sessions on the process's MLX runtime.
internal actor MLXSessionLeaseGate {
    static let shared = MLXSessionLeaseGate()
    private var owner: UUID?
    private var waiters: [(id: UUID, ready: OneShotChannel<Void>)] = []

    func acquire() async throws -> MLXSessionLease {
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
        return MLXSessionLease(id: id, gate: self)
    }

    fileprivate func release(_ id: UUID) {
        guard owner == id else {
            waiters.removeAll { $0.id == id }
            return
        }
        if waiters.isEmpty {
            owner = nil
        } else {
            let next = waiters.removeFirst()
            owner = next.id
            next.ready.finish(())
        }
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
    private var cached: (repoID: String, model: MLXLoadedModel)?
    private var inFlight: (repoID: String, task: Task<MLXLoadedModel, Error>)?
    private var warming: Set<String> = []
    private let loadModel: @Sendable (String) async throws -> MLXLoadedModel

    public init() {
        loadModel = { repoID in
            MLXLoadedModel(try await Qwen3ASRModel.fromPretrained(repoID))
        }
        doushaLog("[MLXModelStore] state=idle")
    }

    /// Offline failure/cancellation tests inject a loader that never touches
    /// Hugging Face or Metal. The production API always uses fromPretrained.
    internal init(loadModel: @escaping @Sendable (String) async throws -> MLXLoadedModel) {
        self.loadModel = loadModel
        doushaLog("[MLXModelStore] state=idle")
    }

    /// Fire-and-forget preload (engine selected in the menu / app launch). Never throws.
    public nonisolated func warmup(_ model: MLXModelDescriptor) {
        Task { await self.preload(model) }
    }

    internal func acquireSessionLease() async throws -> MLXSessionLease {
        try await MLXSessionLeaseGate.shared.acquire()
    }

    private func preload(_ descriptor: MLXModelDescriptor) async {
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
                _ = try await load(descriptor, lease: lease)
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
    internal func load(_ descriptor: MLXModelDescriptor, lease: MLXSessionLease) async throws -> MLXLoadedModel {
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
