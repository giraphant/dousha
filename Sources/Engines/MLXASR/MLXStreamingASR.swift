import Foundation
import ASRSupport
import ConcurrencySupport
import MLXAudioSTT
import MLX

/// The tap only appends bytes under this lock. Swapping the buffer on drain
/// keeps conversion, inference, actor hops, tasks and logging off the audio thread.
/// Generation checks also protect queued main-thread callbacks after restart.
internal final class MLXSessionInput: Sendable {
    private struct State {
        var generation = SessionGeneration()
        var pcm = Data()
        var fullPCM = Data()
        var accepting = false
        var cancelled = false
        var completed = false
    }
    private let state = Lock(State())

    var generation: Generation { state.withLock { $0.generation.live } }

    func prepare() -> Generation {
        state.withLock {
            $0.pcm = Data()
            $0.fullPCM = Data()
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
            $0.fullPCM.append(pcm)
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

    func fullAudio(_ generation: Generation) -> Data {
        state.withLock {
            guard $0.generation.isCurrent(generation), !$0.cancelled else { return Data() }
            return $0.fullPCM
        }
    }

    func cancel(_ generation: Generation) {
        state.withLock {
            guard $0.generation.isCurrent(generation) else { return }
            $0.accepting = false
            $0.cancelled = true
            $0.pcm = Data()
            $0.fullPCM = Data()
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
            $0.fullPCM = Data()
            return true
        }
    }
}

/// Display events are authoritative cumulative snapshots. The separate
/// confirmed/provisional events are not deltas to append a second time.
internal struct MLXTranscriptState {
    let suppressIncompleteHeaders: Bool
    private(set) var display = PartialTranscript.empty

    init(suppressIncompleteHeaders: Bool = false) {
        self.suppressIncompleteHeaders = suppressIncompleteHeaders
    }

    mutating func consume(_ event: TranscriptionEvent) -> PartialTranscript? {
        guard case .displayUpdate(let confirmed, let provisional) = event else { return nil }
        display = MLXPreviewRepetitionGuard.partial(
            QwenTranscriptFilter.partial(confirmed: confirmed, provisional: provisional,
                                         suppressIncompleteTail: suppressIncompleteHeaders))
        return display
    }

    func finalText(endedText: String?) -> String {
        guard let endedText else { return display.combined } // Already filtered for timeout fallback.
        return MLXPreviewRepetitionGuard.collapse(
            QwenTranscriptFilter.visibleText(endedText, suppressIncompleteTail: suppressIncompleteHeaders))
    }
}

/// Internal offline seam: a fake stream and batch runner exercise the actual
/// stop/cancel/lease lifecycle without constructing any MLX arrays or models.
internal protocol MLXStreamingSession: Sendable {
    var events: AsyncStream<TranscriptionEvent> { get }
    func feedAudio(samples: [Float])
    func stop()
    func cancel()
}

extension StreamingInferenceSession: MLXStreamingSession {}

internal struct MLXFinalPassRequest: Sendable {
    let pcm: Data
    let language: String?
    let context: String
}

internal struct MLXPreparedSession: Sendable {
    let stream: any MLXStreamingSession
    let finalPass: @Sendable (MLXFinalPassRequest) async throws -> String
}

public struct MLXFinalPassMetrics: Sendable {
    public let source: String
    /// Elapsed batch time at delivery; on a deadline this is not its eventual runtime.
    public let batchMilliseconds: Double
    public let audioSeconds: Double
    public let streamLength: Int
    public let finalLength: Int
}

private final class MLXFinalPassWork: Sendable {
    struct Output: Sendable {
        let text: String
        let milliseconds: Double
    }
    let result = OneShotChannel<Output>(Output.self)
    let ready = OneShotChannel<Void>()
    private struct State {
        var startedAt: TimeInterval?
        var abandoned = false
    }
    private let state = Lock(State())

    func begin() -> Bool {
        let started = state.withLock {
            guard !$0.abandoned else { return false }
            $0.startedAt = ProcessInfo.processInfo.systemUptime
            return true
        }
        if started { ready.finish(()) }
        return started
    }

    func abandon() { state.withLock { $0.abandoned = true } }

    func complete(_ text: String, milliseconds: Double = 0) {
        let output = state.withLock {
            Output(text: $0.abandoned ? "" : text,
                   milliseconds: milliseconds)
        }
        result.finish(output)
        ready.finish(())
    }

    var elapsedMilliseconds: Double {
        state.withLock { $0.startedAt.map { (ProcessInfo.processInfo.systemUptime - $0) * 1_000 } ?? 0 }
    }
}

/// All caller-side MLX operations are serialized on this private background
/// queue, including the final drain and cancel. The upstream session supplies
/// its own synchronization for detached decoder work and events.
private final class MLXSessionIO: Sendable {
    let session: any MLXStreamingSession
    let queue = DispatchQueue(label: "com.dousha.mlx-asr.feed", qos: .userInitiated)
    let input: MLXSessionInput
    let generation: Generation
    private let cancelled = Lock(false)
    let cancelFinished = OneShotChannel<Void>()

    init(session: any MLXStreamingSession, input: MLXSessionInput, generation: Generation) {
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
    private let finalPassEnabled: Bool
    private let finalPassTimeout: TimeInterval
    private let streamEndTimeout: TimeInterval
    private let streamCleanupTimeout: TimeInterval
    internal typealias SessionFactory = @Sendable (MLXModelDescriptor, MLXModelStore, MLXSessionLease, String?) async throws -> MLXPreparedSession
    private let makeSession: SessionFactory
    public private(set) var finalPassMetrics: MLXFinalPassMetrics?
    private nonisolated let input = MLXSessionInput()

    /// Accessed only on this actor. Tasks carry generation-specific channels,
    /// never mutable pointers to another recording's completion or transcript.
    private final class Recording {
        let generation: Generation
        let traceId = UUID().uuidString.lowercased()
        let started = Date()
        let language: String?
        let context: String
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
        var finalPassRunner: (@Sendable (MLXFinalPassRequest) async throws -> String)?
        var finalPassWork: MLXFinalPassWork?
        var transcript: MLXTranscriptState
        var failure: MLXASRError?
        var stopping = false
        var terminated = false
        var lastStatsAt: Date?

        init(generation: Generation, language: String?, context: String,
             onPartial: @escaping @Sendable (PartialTranscript) -> Void,
             onError: @escaping @Sendable (Error) -> Void) {
            self.generation = generation
            self.language = language
            self.context = context
            self.transcript = MLXTranscriptState(suppressIncompleteHeaders: language == nil)
            self.onPartial = onPartial
            self.onError = onError
        }
    }
    private var recording: Recording?

    public init(model: MLXModelDescriptor = MLXModelCatalog.defaultModel, store: MLXModelStore = .shared,
                finalPass: Bool = true, finalPassTimeout: TimeInterval = 30) {
        self.model = model
        self.store = store
        self.finalPassEnabled = finalPass
        self.finalPassTimeout = max(0, finalPassTimeout)
        self.streamEndTimeout = 10
        self.streamCleanupTimeout = 3
        self.makeSession = Self.makeNativeSession
    }

    internal init(store: MLXModelStore = .shared, finalPass: Bool = true,
                  finalPassTimeout: TimeInterval = 30, streamEndTimeout: TimeInterval = 10,
                  streamCleanupTimeout: TimeInterval = 3, makeSession: @escaping SessionFactory) {
        self.model = MLXModelCatalog.defaultModel
        self.store = store
        self.finalPassEnabled = finalPass
        self.finalPassTimeout = max(0, finalPassTimeout)
        self.streamEndTimeout = streamEndTimeout
        self.streamCleanupTimeout = streamCleanupTimeout
        self.makeSession = makeSession
    }

    private static func makeNativeSession(_ descriptor: MLXModelDescriptor, _ store: MLXModelStore,
                                          _ lease: MLXSessionLease, _ language: String?) async throws -> MLXPreparedSession {
        let loaded = try await store.load(descriptor, lease: lease)
        try Task.checkCancellation()
        // Construction and generation both allocate MLX arrays; run off main.
        return await Task.detached(priority: .userInitiated) {
            MLXPreparedSession(
                stream: StreamingInferenceSession(model: loaded.model, config: StreamingConfig(language: language)),
                finalPass: { request in
                    let samples = MLXASRSupport.floatSamples(fromPCM16LE: request.pcm)
                    guard !samples.isEmpty else { return "" }
                    return loaded.model.generate(audio: MLXArray(samples), maxTokens: 8192,
                                                 temperature: 0, context: request.context,
                                                 language: request.language, chunkDuration: 1200,
                                                 minChunkDuration: 1, repetitionPenalty: 1.15,
                                                 repetitionContextSize: 32).text
                })
        }.value
    }

    /// `language` is a Dousha identifier (e.g. "zh-CN"), mapped once via
    /// MLXASRSupport.qwenLanguage(forIdentifier:); nil, "auto" and unknown
    /// identifiers select auto-detection, not Qwen3's default English.
    public func prepareSession(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                               onError: @escaping @Sendable (Error) -> Void,
                               language: String?, context: String = "") {
        if let previous = recording {
            previous.terminated = true
            previous.setupTask?.cancel()
            previous.finalPassWork?.abandon()
            previous.finalPassWork?.result.finish(throwing: CancellationError())
            _ = startCleanup(previous)
        }
        let generation = input.prepare()
        finalPassMetrics = nil
        let current = Recording(generation: generation,
                                language: language.flatMap(MLXASRSupport.qwenLanguage(forIdentifier:)),
                                context: context,
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
            let prepared = try await makeSession(model, store, lease, current.language)
            let io = MLXSessionIO(session: prepared.stream, input: input, generation: current.generation)
            current.io = io
            current.lease = lease
            current.finalPassRunner = prepared.finalPass
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
            recordFinalPass(current, text: "", fallback: "", batchMilliseconds: 0,
                            audioSeconds: Double(input.fullAudio(generation).count / 2) / 16_000)
            deliverCompletion("", current: current, completion: completion)
            return
        }

        // Serial queue ordering: any feed already in progress returns before
        // the remaining buffered tail is fed and the model's stop is invoked.
        io.finish()
        let ended = await current.final.wait(timeout: streamEndTimeout)
        guard isCurrent(current) else { return }
        let fallback: String
        if case .signaled(let fullText) = ended {
            fallback = current.transcript.finalText(endedText: fullText)
        } else {
            fallback = current.transcript.finalText(endedText: nil)
            log(current, "finalTimedOut fallbackLength=\(fallback.count)")
        }
        let pcm = input.fullAudio(generation)
        let audioSeconds = Double(pcm.count / 2) / 16_000
        let work = startFinalPass(current, pcm: pcm)
        // Includes up to 3s for streaming cleanup. After a streaming timeout,
        // natural .ended is still required before batch inference can start.
        // A detached owner retains the lease if either stage exceeds this wait.
        let output: WaitOutcome<MLXFinalPassWork.Output>
        if case .signaled = await work.ready.wait(timeout: streamCleanupTimeout) {
            output = await work.result.wait(timeout: max(0, finalPassTimeout - work.elapsedMilliseconds / 1_000))
        } else {
            output = .timeout
        }
        work.abandon()
        guard isCurrent(current) else { return }
        let batch: String
        let milliseconds: Double
        if case .signaled(let value) = output, value.milliseconds <= finalPassTimeout * 1_000 {
            batch = value.text
            milliseconds = value.milliseconds
        } else {
            batch = ""
            milliseconds = work.elapsedMilliseconds
        }
        let text = batch.isEmpty ? fallback : batch
        recordFinalPass(current, text: text, fallback: fallback, batchMilliseconds: milliseconds,
                        audioSeconds: audioSeconds, source: batch.isEmpty ? "stream" : "batch")
        deliverCompletion(text, current: current, completion: completion)
    }

    /// Transfers the captured streaming resources and lease to one detached
    /// owner. Cancel/restart cannot release this lease while generate is running.
    private func startFinalPass(_ current: Recording, pcm: Data) -> MLXFinalPassWork {
        let work = MLXFinalPassWork()
        current.finalPassWork = work
        guard let io = current.io, let lease = current.lease, let runner = current.finalPassRunner else {
            work.complete("")
            return work
        }
        current.io = nil
        current.lease = nil
        current.finalPassRunner = nil
        let cleanupFinished = OneShotChannel<Void>()
        current.cleanupFinished = cleanupFinished
        let final = current.final
        let eventsFinished = current.eventsFinished
        let eventTask = current.eventTask
        let input = self.input
        let generation = current.generation
        let request = MLXFinalPassRequest(pcm: pcm, language: current.language, context: current.context)
        let enabled = finalPassEnabled
        Task.detached(priority: .userInitiated) {
            // cancel() only closes the upstream event stream; it does NOT join
            // its decoder. On a timeout let stop finish naturally before cancel,
            // otherwise a batch could overlap that still-running decoder.
            let ended = try? await final.wait()
            io.cancel()
            _ = try? await io.cancelFinished.wait()
            if case .timeout = await eventsFinished.wait(timeout: 3) { eventTask?.cancel() }
            var text = ""
            if ended != nil, enabled, !request.pcm.isEmpty, input.permitsCallback(generation), work.begin() {
                // Qwen's batch parser already strips auto-language metadata;
                // filter defensively for both forced and automatic modes.
                if let generated = try? await runner(request) {
                    text = QwenTranscriptFilter.visibleText(generated, suppressIncompleteTail: request.language == nil)
                }
            }
            let milliseconds = work.elapsedMilliseconds
            await lease.release()
            cleanupFinished.finish(())
            work.complete(text, milliseconds: milliseconds)
        }
        return work
    }

    private func recordFinalPass(_ current: Recording, text: String, fallback: String,
                                 batchMilliseconds: Double, audioSeconds: Double, source: String = "stream") {
        finalPassMetrics = MLXFinalPassMetrics(source: source, batchMilliseconds: batchMilliseconds,
                                               audioSeconds: audioSeconds, streamLength: fallback.count,
                                               finalLength: text.count)
        log(current, "finalPass source=\(source) batchMs=\(Int(batchMilliseconds)) audioSeconds=\(audioSeconds) streamLength=\(fallback.count) finalLength=\(text.count)")
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
        current.finalPassWork?.abandon()
        current.finalPassWork?.result.finish(throwing: CancellationError())
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
        current.finalPassRunner = nil
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
