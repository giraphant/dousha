import Foundation
import ASRSupport
import ConcurrencySupport
import MLXAudioSTT

/// The tap only appends bytes under this lock. Swapping the buffer on drain
/// keeps conversion, inference, actor hops, tasks and logging off the audio thread.
/// Generation checks also protect queued main-thread callbacks after restart.
internal final class MLXSessionInput: Sendable {
    private struct State {
        var generation = SessionGeneration()
        var pcm = Data()
        var accepting = false
        var cancelled = false
        var completed = false
    }
    private let state = Lock(State())

    var generation: Generation { state.withLock { $0.generation.live } }

    func prepare() -> Generation {
        state.withLock {
            $0.pcm = Data()
            $0.accepting = true
            $0.cancelled = false
            $0.completed = false
            return $0.generation.bump()
        }
    }

    func append(_ pcm: Data) {
        state.withLock {
            guard $0.accepting else { return }
            $0.pcm.append(pcm)
        }
    }

    func drain(_ generation: Generation, final: Bool = false) -> Data {
        state.withLock {
            guard $0.generation.isCurrent(generation), !$0.cancelled,
                  final || $0.accepting else { return Data() }
            // Preserve a split int16 sample between tap chunks. Only an odd
            // final byte (malformed PCM) is discarded when the session ends.
            let count = $0.pcm.count - $0.pcm.count % 2
            if count == $0.pcm.count {
                let pcm = $0.pcm
                $0.pcm = Data()
                return pcm
            }
            let pcm = Data($0.pcm.prefix(count))
            $0.pcm = Data($0.pcm.suffix(1))
            return pcm
        }
    }

    func stopAccepting(_ generation: Generation) {
        state.withLock {
            if $0.generation.isCurrent(generation) { $0.accepting = false }
        }
    }

    func cancel(_ generation: Generation) {
        state.withLock {
            guard $0.generation.isCurrent(generation) else { return }
            $0.accepting = false
            $0.cancelled = true
            $0.pcm = Data()
        }
    }

    func permitsCallback(_ generation: Generation) -> Bool {
        state.withLock {
            $0.generation.isCurrent(generation) && !$0.cancelled && !$0.completed
        }
    }

    func claimCompletion(_ generation: Generation) -> Bool {
        state.withLock {
            guard $0.generation.isCurrent(generation), !$0.cancelled, !$0.completed else { return false }
            $0.completed = true
            $0.accepting = false
            $0.pcm = Data()
            return true
        }
    }
}

/// Display events are authoritative cumulative snapshots. The separate
/// confirmed/provisional events are not deltas to append a second time.
internal struct MLXTranscriptState {
    private(set) var display = PartialTranscript.empty

    mutating func consume(_ event: TranscriptionEvent) -> PartialTranscript? {
        guard case .displayUpdate(let confirmed, let provisional) = event else { return nil }
        display = PartialTranscript(finalText: confirmed, interimText: provisional)
        return display
    }

    func finalText(endedText: String?) -> String { endedText ?? display.combined }
}

/// All caller-side MLX operations are serialized on this private background
/// queue, including the final drain and cancel. The upstream session supplies
/// its own synchronization for detached decoder work and events.
private final class MLXSessionIO: Sendable {
    let session: StreamingInferenceSession
    let queue = DispatchQueue(label: "com.dousha.mlx-asr.feed", qos: .userInitiated)
    let input: MLXSessionInput
    let generation: Generation
    private let cancelled = Lock(false)
    let cancelFinished = OneShotChannel<Void>()

    init(session: StreamingInferenceSession, input: MLXSessionInput, generation: Generation) {
        self.session = session
        self.input = input
        self.generation = generation
    }

    func feed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                defer { continuation.resume() }
                guard !self.cancelled.value() else { return }
                self.feedBuffered(final: false)
            }
        }
    }

    func finish() {
        queue.async {
            guard !self.cancelled.value() else { return }
            self.feedBuffered(final: true)
            self.session.stop()
        }
    }

    func cancel() {
        let first = cancelled.withLock { value in
            if value { return false }
            value = true
            return true
        }
        guard first else { return }
        queue.async {
            self.session.cancel()
            self.cancelFinished.finish(())
        }
    }

    private func feedBuffered(final: Bool) {
        let pcm = input.drain(generation, final: final)
        guard !pcm.isEmpty else { return }
        session.feedAudio(samples: MLXASRSupport.floatSamples(fromPCM16LE: pcm))
    }
}

/// One local streaming recognizer per recording. The input lock is the only
/// tap-thread state; lifecycle and per-recording bookkeeping are actor-isolated.
public actor MLXStreamingASR {
    private let model: MLXModelDescriptor
    private let store: MLXModelStore
    private nonisolated let input = MLXSessionInput()

    /// Accessed only on this actor. Tasks carry generation-specific channels,
    /// never mutable pointers to another recording's completion or transcript.
    private final class Recording {
        let generation: Generation
        let traceId = UUID().uuidString.lowercased()
        let started = Date()
        let language: String?
        let onPartial: @Sendable (PartialTranscript) -> Void
        let onError: @Sendable (Error) -> Void
        let setupFinished = OneShotChannel<Void>()
        let final = OneShotChannel<String>(String.self)
        let eventsFinished = OneShotChannel<Void>()
        var setupTask: Task<Void, Never>?
        var feederTask: Task<Void, Never>?
        var eventTask: Task<Void, Never>?
        var cleanupFinished: OneShotChannel<Void>?
        var io: MLXSessionIO?
        var lease: MLXSessionLease?
        var transcript = MLXTranscriptState()
        var failure: MLXASRError?
        var stopping = false
        var terminated = false
        var lastStatsAt: Date?

        init(generation: Generation, language: String?,
             onPartial: @escaping @Sendable (PartialTranscript) -> Void,
             onError: @escaping @Sendable (Error) -> Void) {
            self.generation = generation
            self.language = language
            self.onPartial = onPartial
            self.onError = onError
        }
    }
    private var recording: Recording?

    public init(model: MLXModelDescriptor = MLXModelCatalog.defaultModel, store: MLXModelStore = .shared) {
        self.model = model
        self.store = store
    }

    public func prepareSession(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                               onError: @escaping @Sendable (Error) -> Void,
                               language: String?) {
        if let previous = recording {
            previous.terminated = true
            previous.setupTask?.cancel()
            _ = startCleanup(previous)
        }
        let generation = input.prepare()
        let current = Recording(generation: generation,
                                language: language.flatMap(MLXASRSupport.qwenLanguage(forIdentifier:)),
                                onPartial: onPartial, onError: onError)
        recording = current
        log(current, "prepareSession repoID=\(model.repoID) language=\(current.language ?? "auto")")
    }

    public nonisolated func openStream() {
        let generation = input.generation
        Task { await self.beginOpen(generation) }
    }

    private func beginOpen(_ generation: Generation) {
        guard let current = recording, current.generation == generation,
              !current.terminated, current.setupTask == nil,
              input.permitsCallback(generation) else { return }
        current.setupTask = Task { await self.setUp(current) }
    }

    private func setUp(_ current: Recording) async {
        defer { current.setupFinished.finish(()) }
        var acquiredLease: MLXSessionLease?
        do {
            let lease = try await store.acquireSessionLease()
            acquiredLease = lease
            try Task.checkCancellation()
            let loaded = try await store.load(model, lease: lease)
            try Task.checkCancellation()
            guard isCurrent(current) else { throw CancellationError() }
            let language = current.language
            // Even construction may allocate MLX arrays: do it off the main
            // thread, with the lease already held. Never rely on config's
            // default language (English); nil explicitly means auto-detect.
            let session = await Task.detached(priority: .userInitiated) {
                StreamingInferenceSession(model: loaded.model, config: StreamingConfig(language: language))
            }.value
            let io = MLXSessionIO(session: session, input: input, generation: current.generation)
            current.io = io
            current.lease = lease
            acquiredLease = nil
            startEventConsumer(current, io: io)
            guard isCurrent(current), !Task.isCancelled else {
                _ = startCleanup(current)
                return
            }
            if !current.stopping {
                current.feederTask = Task.detached(priority: .userInitiated) {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(100)) }
                        catch { return }
                        guard !Task.isCancelled else { return }
                        await io.feed()
                    }
                }
            }
            log(current, "streamReady setupMs=\(Int(Date().timeIntervalSince(current.started) * 1000))")
        } catch {
            if let acquiredLease { await acquiredLease.release() }
            guard isCurrent(current), !(error is CancellationError) else { return }
            let failure = MLXASRError.modelLoadFailed(error.localizedDescription)
            current.failure = failure
            input.stopAccepting(current.generation)
            log(current, "modelLoadFailed error=\(error.localizedDescription)")
            deliverError(failure, current: current)
        }
    }

    /// Called directly by the audio tap. No tasks, logging, actor hops or MLX.
    public nonisolated func ingest(_ pcm: Data) { input.append(pcm) }

    private func startEventConsumer(_ current: Recording, io: MLXSessionIO) {
        let generation = current.generation
        let final = current.final
        let eventsFinished = current.eventsFinished
        current.eventTask = Task.detached { [weak self] in
            for await event in io.session.events {
                // Signal this session's wait BEFORE checking staleness, just as
                // the peer engines signal their detached close handshakes.
                if case .ended(let text) = event { final.finish(text) }
                await self?.consume(event, generation: generation)
            }
            final.finish(throwing: MLXASRError.modelNotReady)
            eventsFinished.finish(())
        }
    }

    private func consume(_ event: TranscriptionEvent, generation: Generation) {
        guard let current = recording, current.generation == generation,
              isCurrent(current) else { return }
        if let partial = current.transcript.consume(event) {
            let callback = current.onPartial
            let input = self.input
            DispatchQueue.main.async {
                guard input.permitsCallback(generation) else { return }
                callback(partial)
            }
        }
        if case .stats(let stats) = event {
            let now = Date()
            guard current.lastStatsAt.map({ now.timeIntervalSince($0) >= 3 }) ?? true else { return }
            current.lastStatsAt = now
            log(current, "stats rtf=\(stats.realTimeFactor) peakMemoryGB=\(stats.peakMemoryGB) audioSeconds=\(stats.totalAudioSeconds)")
        }
    }

    public nonisolated func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        let generation = input.generation
        Task { await self.finish(generation, completion: completion) }
    }

    private func finish(_ generation: Generation,
                        completion: @escaping @Sendable (TranscriptionResult) -> Void) async {
        guard let current = recording, current.generation == generation,
              !current.stopping, isCurrent(current) else { return }
        current.stopping = true
        // The hub already drained its tap; yield to any last push before
        // closing the input gate, including immediately stopped replay input.
        for _ in 0..<4 { await Task.yield() }
        guard isCurrent(current) else { return }
        input.stopAccepting(generation)
        current.feederTask?.cancel()
        log(current, "stop setupWaitSeconds=30")
        let setup = await current.setupFinished.wait(timeout: 30)
        guard isCurrent(current) else { return }
        guard case .signaled = setup, let io = current.io else {
            current.setupTask?.cancel()
            if current.failure == nil {
                current.failure = .modelNotReady
                log(current, "setupTimedOut")
                deliverError(MLXASRError.modelNotReady, current: current)
            }
            _ = startCleanup(current)
            deliverCompletion("", current: current, completion: completion)
            return
        }

        // Serial queue ordering: any feed already in progress returns before
        // the remaining buffered tail is fed and the model's stop is invoked.
        io.finish()
        let ended = await current.final.wait(timeout: 10)
        guard isCurrent(current) else { return }
        let text: String
        if case .signaled(let fullText) = ended {
            text = current.transcript.finalText(endedText: fullText)
        } else {
            text = current.transcript.finalText(endedText: nil)
            log(current, "finalTimedOut fallbackLength=\(text.count)")
        }
        let cleanup = startCleanup(current)
        // Normally cancel + stream close are immediate. If a synchronous MLX
        // call is stuck, return the bounded result while cleanup retains the
        // lease until that call returns; never start competing inference.
        _ = await cleanup.wait(timeout: 3)
        guard isCurrent(current) else { return }
        deliverCompletion(text, current: current, completion: completion)
    }

    public nonisolated func cancel() {
        let generation = input.generation
        input.cancel(generation) // Quarantine callbacks and the tap immediately.
        Task { await self.cancelRecording(generation) }
    }

    private func cancelRecording(_ generation: Generation) {
        guard let current = recording, current.generation == generation else { return }
        current.terminated = true
        current.setupTask?.cancel()
        _ = startCleanup(current)
        log(current, "cancel")
    }

    /// Cleanup owns a captured lease, IO object and channels, so a stale task
    /// cannot release a newer recording's lease or overwrite its lifecycle.
    @discardableResult
    private func startCleanup(_ current: Recording) -> OneShotChannel<Void> {
        current.feederTask?.cancel()
        current.feederTask = nil
        if let finished = current.cleanupFinished { return finished }
        // During model loading, setUp still owns the lease and releases it
        // after cancellation/load settles. Do not memoize an empty cleanup:
        // setup can still hand us an IO object after an async construction.
        guard let io = current.io, let lease = current.lease else {
            let finished = OneShotChannel<Void>()
            finished.finish(())
            return finished
        }
        current.io = nil
        current.lease = nil
        let finished = OneShotChannel<Void>()
        current.cleanupFinished = finished
        let eventsFinished = current.eventsFinished
        let eventTask = current.eventTask
        let traceId = current.traceId
        io.cancel()
        Task.detached {
            let cancellation = await io.cancelFinished.wait(timeout: 3)
            if case .timeout = cancellation {
                doushaLog("[MLXASR] traceId=\(traceId) cancelTimedOut waitingForFeed; retainingLease")
                _ = try? await io.cancelFinished.wait()
            }
            // Upstream cancel finishes the event stream but is not an
            // awaitable decoder barrier. This is its strongest exposed signal.
            if case .timeout = await eventsFinished.wait(timeout: 3) {
                doushaLog("[MLXASR] traceId=\(traceId) cancelTimedOut waitingForEvents")
                eventTask?.cancel()
            }
            await lease.release()
            finished.finish(())
        }
        return finished
    }

    private func isCurrent(_ current: Recording) -> Bool {
        recording === current && !current.terminated && input.permitsCallback(current.generation)
    }

    private func deliverError(_ error: MLXASRError, current: Recording) {
        let input = self.input
        let generation = current.generation
        let callback = current.onError
        DispatchQueue.main.async {
            guard input.permitsCallback(generation) else { return }
            callback(error)
        }
    }

    private func deliverCompletion(_ text: String, current: Recording,
                                   completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        let input = self.input
        let generation = current.generation
        let result = TranscriptionResult(text: text, traceId: current.traceId)
        log(current, "stop finalLength=\(text.count)")
        DispatchQueue.main.async {
            guard input.claimCompletion(generation) else { return }
            completion(result)
        }
    }

    private func log(_ current: Recording, _ message: String) {
        doushaLog("[MLXASR] traceId=\(current.traceId) \(message)")
    }
}
