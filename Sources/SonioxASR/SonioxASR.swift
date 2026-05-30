import Foundation
import AVFoundation
import TalkerCommonSync
import ASRSupport

/// Streaming Soniox real-time STT client. One recording per instance:
/// `start()` opens the mic + WebSocket and streams raw PCM s16le; `stop()`
/// sends the end-of-audio marker and waits for the server's `finished` flush.
///
/// Much simpler than Doubao: no device registration, JWT, Opus, or protobuf.
/// The first WS message is a JSON config (text frame) carrying the API key and
/// audio format; every subsequent frame is binary PCM. End-of-audio is an empty
/// binary frame (`.data(Data())`), matching the JS reference's `ArrayBuffer(0)`.
public actor SonioxASR {
    private let apiKey: String
    private let mode: SonioxMode

    /// Glossary terms sent in Soniox's `context.terms` to bias recognition
    /// toward domain words / proper nouns (QUA-133). Snapshotted at
    /// `start(contextTerms:)` so a Settings change mid-recording can't alter the
    /// active session, and reused by `retranscribe` so a replay stays consistent
    /// with the recording that produced the audio. Empty => no `context` sent.
    private var contextTerms: [String] = []

    private var session: URLSession?
    private var ws: URLSessionWebSocketTask?

    /// Bumped on every openWebSocket(). The receive loop captures the value at
    /// schedule time and drops any callback whose generation no longer matches
    /// the current socket — so a stray in-flight message from a socket closed
    /// during retranscribe/reconnect can't mutate fresh-session state. Mirrors
    /// the JS reference's `_isOld` old-socket guard.
    private var wsGeneration = 0

    // State
    private var requestId: String = UUID().uuidString.lowercased()
    private var pcmBuffer = Data()
    private var canSendAudio = false
    private var isRunning = false
    private var parser = SonioxResponseParser()

    /// Fresh per session — recreated in _start() so a prior session's signal
    /// doesn't leak forward.
    private var finishedChannel: OneShotChannel<Void>?

    /// Signaled by the receive loop once the WS has fully torn down, so
    /// closeWebSocket() can wait for the server's Close ack before invalidating
    /// the URLSession. Keyed by the closing socket's generation so a stale
    /// socket's trailing failure only wakes its own waiter, never a newer
    /// overlapping close's (QUA-130).
    private var wsCloseChannels = GenerationCloseChannels()

    /// Periodic keepalive control frame. Started only AFTER the config message
    /// is sent (the first frame must be config), and cancelled in
    /// closeWebSocket() and on receive-loop failure. Without it the server tears
    /// down idle connections, which on a long recording with mid-sentence
    /// pauses cuts the recording off early.
    private var keepaliveTask: Task<Void, Never>?

    // Callbacks (assigned in prepareSession). Audio level is owned by the
    // AudioTapHub now, so the engine no longer forwards it.
    private var onPartial: (@Sendable (PartialTranscript) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?

    private var totalPcmBytesOut: Int = 0

    /// When audio capture began for this session. Set in `prepareSession`
    /// (the mic + shared WAV are owned by the `AudioTapHub`); drives the
    /// reported `audioDuration`.
    private var audioStartedAt: Date?
    private var lastResponseAt: Date?
    private var lastTranscriptAt: Date?

    /// Creates an idle recognizer. No mic, network, or key validation happens
    /// until `prepareSession()` / `openStream()`. `mode` picks real-time
    /// WebSocket streaming or async (batch) upload-on-stop.
    public init(apiKey: String, mode: SonioxMode = .realtime) {
        self.apiKey = apiKey
        self.mode = mode
    }

    // MARK: - Lifecycle

    /// Phase 1 — reset session state and mark the engine ready to accept pushed
    /// PCM, without touching the network. `MultiEngineBackend` awaits this for
    /// every engine BEFORE starting the shared `AudioTapHub`, so a buffer pushed
    /// the instant the mic goes live can't arrive before `isRunning` flips. Mic
    /// capture + the shared WAV are now owned by the hub; audio arrives via
    /// `ingest(_:)`.
    ///
    /// - Parameter contextTerms: Glossary terms for Soniox's `context.terms`.
    ///   Pass `[]` for none. Snapshotted for the duration of this recording.
    public func prepareSession(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                               onError: @escaping @Sendable (Error) -> Void,
                               contextTerms: [String] = []) {
        guard !isRunning else { return }
        isRunning = true
        self.contextTerms = contextTerms
        self.onPartial = onPartial
        self.onError = onError
        self.parser = SonioxResponseParser()
        self.pcmBuffer = Data()
        self.canSendAudio = false
        self.totalPcmBytesOut = 0
        self.requestId = UUID().uuidString.lowercased()
        self.finishedChannel = OneShotChannel<Void>()
        self.audioStartedAt = Date()
        self.lastResponseAt = nil
        self.lastTranscriptAt = nil
        doushaLog("[SonioxASR] traceId=\(requestId) prepareSession mode=\(mode.rawValue) (capture owned by AudioTapHub)")
    }

    /// Phase 2 — for realtime mode, open the WebSocket, send the config frame,
    /// and flush whatever PCM buffered during setup. Async mode is a no-op here:
    /// it has no live socket; the whole shared WAV is uploaded to the batch REST
    /// API on `stop()`. Fire-and-forget so the hub's capture overlaps setup.
    public nonisolated func openStream() {
        Task { await self._openStream() }
    }

    private func _openStream() async {
        guard isRunning else { return }

        guard !apiKey.isEmpty else {
            let err = NSError(domain: "SonioxASR", code: 401,
                              userInfo: [NSLocalizedDescriptionKey: "Soniox API key is missing. Add it in Settings."])
            deliverError(err)
            isRunning = false
            signalFinished()
            return
        }

        // Async mode streams nothing live — the shared WAV (written by the hub)
        // is uploaded to the batch REST API on stop().
        guard mode == .realtime else {
            doushaLog("[SonioxASR] traceId=\(requestId) async mode — WAV-only capture, no WS")
            return
        }

        do {
            try openWebSocket()
            try await sendConfigMessage()
            doushaLog("[SonioxASR] traceId=\(requestId) config sent pcmBufferBytes=\(pcmBuffer.count)")

            // Keepalive only after the config frame is on the wire (the first
            // frame must be config). Flip the audio gate for the same reason.
            startKeepalive()
            self.canSendAudio = true
            try await flushPendingFrames()
        } catch {
            doushaLog("[SonioxASR] openStream() failed: \(error.localizedDescription)")
            deliverError(error)
            await closeWebSocket()
            isRunning = false
            signalFinished()
        }
    }

    /// Push one chunk of int16 16 kHz mono PCM from the shared `AudioTapHub`.
    /// Replaces the old internal mic-tap callback. A no-op in async mode (the
    /// WAV side-recording is the payload there).
    public nonisolated func ingest(_ pcm: Data) {
        Task { await self.appendAndDrainPCM(pcm) }
    }

    /// Aborts the current recording without sending end-of-audio, discarding any
    /// pending transcript and the side-recorded WAV. Quarantines callbacks
    /// before teardown so a stray frame can't bleed into the error path.
    /// Safe to call when not running.
    public nonisolated func cancel() {
        Task { await self._cancel() }
    }

    private func _cancel() async {
        doushaLog("[SonioxASR] cancel() isRunning=\(isRunning)")
        guard isRunning else { return }
        isRunning = false

        self.onPartial = nil
        self.onError = nil

        // Mic capture + the shared WAV are owned by the AudioTapHub, which the
        // coordinator cancels separately — nothing to tear down here.

        await closeWebSocket()
        signalFinished()
        doushaLog("[SonioxASR] cancel() done")
    }

    /// Stops capturing the mic, sends the empty-binary end-of-audio marker, and
    /// waits up to ~5s for the server's `finished` flush. Completion fires
    /// exactly once on the main queue.
    public nonisolated func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        Task {
            let result = await self._stop()
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func _stop() async -> TranscriptionResult {
        doushaLog("[SonioxASR] stop() isRunning=\(isRunning)")
        guard isRunning else {
            return makeResult()
        }

        // The shared AudioTapHub has already removed the mic tap and held its own
        // drain window before calling us. Yield a few times so the last pushed
        // buffers (the tail) land in pcmBuffer before we flip isRunning=false
        // (which would otherwise drop them via the ingest guard).
        for _ in 0..<4 { await Task.yield() }
        isRunning = false

        if mode == .async {
            return await stopAsync()
        }

        do {
            try await flushPendingFrames()
            try await flushLastPartialFrame()
            try await sendEndOfAudio()
        } catch {
            doushaLog("[SonioxASR] stop send error: \(error.localizedDescription)")
        }

        // Wait for `finished: true`. Soniox flushes promptly; 5s is generous.
        let waitStart = Date()
        if let channel = finishedChannel {
            _ = await waitWithTimeout(channel: channel, timeout: 5.0)
        }
        doushaLog("[SonioxASR] traceId=\(requestId) post-EOS wait \(Int(Date().timeIntervalSince(waitStart) * 1000))ms finished=\(parser.isFinished)")

        // The transcript is final once the finished-wait returns, so build the
        // result and hand it back NOW. The WS close handshake (up to 1s) runs
        // detached so it never delays the paste. We unhook the socket/session
        // from actor state SYNCHRONOUSLY here so a fast restart can't be torn
        // down by the trailing close (see detachAndCloseWebSocketInBackground).
        let result = makeResult()
        doushaLog("[SonioxASR] traceId=\(requestId) stop final text.len=\(result.text.count)")
        detachAndCloseWebSocketInBackground()
        return result
    }

    /// Synchronously unhooks the current socket/session from actor state and
    /// bumps the generation, then runs the up-to-1s WS close handshake in a
    /// detached task. Because `self.ws`/`self.session` are cleared before this
    /// returns, a reentrant `_start()` that opens a fresh socket can't be
    /// clobbered by the trailing close — the handshake operates only on the
    /// captured handles.
    private func detachAndCloseWebSocketInBackground() {
        stopKeepalive()
        guard let closing = ws else {
            session?.invalidateAndCancel()
            session = nil
            return
        }
        let closingSession = session
        // The socket's receive loop runs under the current generation; register
        // the close channel under it BEFORE the bump so the socket's own failure
        // callback (which fires with that generation) wakes this waiter.
        let closingGeneration = wsGeneration
        self.ws = nil
        self.session = nil
        wsGeneration += 1

        let channel = wsCloseChannels.register(closingGeneration)
        closing.cancel(with: .normalClosure, reason: nil)
        Task {
            if case .timeout = await self.waitWithTimeout(channel: channel, timeout: 1.0) {
                doushaLog("[SonioxASR] WS close handshake timed out — tearing down anyway")
            }
            self.wsCloseChannels.remove(closingGeneration)
            closingSession?.invalidateAndCancel()
        }
    }

    /// Async-mode stop: the WAV is already closed; upload it to the batch REST
    /// API and return the server transcript. On any error, surfaces it via
    /// onError and returns an empty-text result (the WAV is preserved so the
    /// retranscribe path can retry).
    private func stopAsync() async -> TranscriptionResult {
        let savedURL = AudioCapturePaths.sharedWAV
        guard FileManager.default.fileExists(atPath: savedURL.path) else {
            doushaLog("[SonioxASR] traceId=\(requestId) async stop — no WAV captured")
            return makeResult()
        }
        let client = SonioxAsyncClient(apiKey: apiKey, contextTerms: contextTerms)
        do {
            let text = try await client.transcribe(fileURL: savedURL, traceId: requestId)
            parser.ingest(object: ["tokens": [["text": text, "is_final": true]], "finished": true])
            doushaLog("[SonioxASR] traceId=\(requestId) async stop text.len=\(text.count)")
        } catch {
            doushaLog("[SonioxASR] traceId=\(requestId) async stop error=\(error.localizedDescription)")
            deliverError(error)
        }
        return makeResult()
    }

    private func makeResult() -> TranscriptionResult {
        let audioDuration: TimeInterval = audioStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let lastResponseAge: TimeInterval? = lastResponseAt.map { Date().timeIntervalSince($0) }
        let lastTranscriptAge: TimeInterval? = lastTranscriptAt.map { Date().timeIntervalSince($0) }
        let savedURL: URL? = FileManager.default.fileExists(atPath: AudioCapturePaths.sharedWAV.path) ? AudioCapturePaths.sharedWAV : nil
        return TranscriptionResult(
            // displayText = finalText + interim. When finished, interim is
            // flushed so this equals finalText; on a finished-wait timeout it
            // preserves the trailing interim instead of dropping it.
            text: parser.displayText,
            audioDuration: audioDuration,
            lastResponseAge: lastResponseAge,
            lastTranscriptAge: lastTranscriptAge,
            maxSegmentGap: nil,
            savedAudioURL: savedURL,
            traceId: requestId
        )
    }

    private func closeWebSocket() async {
        stopKeepalive()
        guard let ws = ws else {
            session?.invalidateAndCancel()
            session = nil
            return
        }
        // Capture the session this close owns. We await the close handshake
        // below, during which actor reentrancy could let a fresh openWebSocket()
        // assign a NEW session into self.session — invalidating self.session
        // after the await would then kill the new socket. Tear down only ours.
        let owningSession = session
        self.ws = nil
        // Register the close channel under the socket's current generation
        // BEFORE the bump so its own failure callback wakes this waiter.
        let closingGeneration = wsGeneration
        // Invalidate the old socket's receive callbacks NOW (before awaiting the
        // close handshake) so a trailing message during the close/reopen gap
        // can't mutate freshly-reset session state (e.g. in retranscribe). The
        // failure callback still signals this generation's channel below — see
        // handleReceiveResult — so the handshake completes promptly.
        wsGeneration += 1

        let channel = wsCloseChannels.register(closingGeneration)
        ws.cancel(with: .normalClosure, reason: nil)

        if case .timeout = await waitWithTimeout(channel: channel, timeout: 1.0) {
            doushaLog("[SonioxASR] WS close handshake timed out — tearing down anyway")
        }
        wsCloseChannels.remove(closingGeneration)

        owningSession?.invalidateAndCancel()
        // Only clear self.session if it still points at the session we closed —
        // a reentrant reopen during the await may have already replaced it.
        if session === owningSession {
            session = nil
        }
    }

    // MARK: - WebSocket

    private func openWebSocket() throws {
        guard let url = URL(string: SonioxConfig.endpoint) else {
            throw URLError(.badURL)
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        let sess = URLSession(configuration: cfg)
        self.session = sess
        self.ws = sess.webSocketTask(with: url)
        self.ws?.resume()
        wsGeneration += 1
        startReceiveLoop(generation: wsGeneration)
        // Keepalive is started by the caller AFTER the config message is sent,
        // so a keepalive text frame can never precede the required first frame.
    }

    private func sendConfigMessage() async throws {
        guard let ws = ws else { throw URLError(.networkConnectionLost) }
        let json = SonioxConfig.configMessageJSON(apiKey: apiKey, contextTerms: contextTerms)
        if contextTerms.isEmpty {
            doushaLog("[SonioxASR] traceId=\(requestId) config context: (none)")
        } else {
            let preview = contextTerms.prefix(8).joined(separator: "、")
            doushaLog("[SonioxASR] traceId=\(requestId) config context.terms=\(contextTerms.count) preview=\(preview)")
        }
        try await ws.send(.string(json))
    }

    private func sendEndOfAudio() async throws {
        guard let ws = ws else { return }
        // Empty BINARY frame — matches the JS ref's `new ArrayBuffer(0)`.
        try await ws.send(.data(Data()))
        doushaLog("[SonioxASR] traceId=\(requestId) sent end-of-audio marker")
    }

    private func startKeepalive() {
        keepaliveTask?.cancel()
        let intervalNs = UInt64(SonioxConfig.keepaliveIntervalSeconds * 1_000_000_000)
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                if Task.isCancelled { return }
                await self?.sendKeepalive()
            }
        }
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    private func sendKeepalive() async {
        guard let ws = ws else { return }
        try? await ws.send(.string(SonioxConfig.keepaliveMessageJSON))
    }

    private func startReceiveLoop(generation: Int) {
        guard let ws = ws else { return }
        ws.receive { [weak self] result in
            Task { await self?.handleReceiveResult(result, generation: generation) }
        }
    }

    private func handleReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, Error>, generation: Int) async {
        switch result {
        case .success(let msg):
            // Drop content from a socket that has since been replaced/closed so
            // a trailing frame can't mutate fresh-session state.
            guard generation == wsGeneration else { return }
            let data: Data
            switch msg {
            case .data(let d):   data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default:    data = Data()
            }
            if !data.isEmpty {
                handleResponseData(data)
            }
            if self.ws != nil {
                startReceiveLoop(generation: generation)
            }
        case .failure(let err):
            // Signal the close handshake BEFORE the generation guard: when
            // closeWebSocket() bumps wsGeneration and cancels the socket, the
            // resulting failure callback is the only thing that wakes the
            // close-await. Gating it behind the guard would make every close
            // block the full 1s timeout. Keying by this callback's own
            // generation ensures a stale socket can't wake a newer close.
            wsCloseChannels.signal(generation)
            guard generation == wsGeneration else { return }
            doushaLog("[SonioxASR] receive failed: \(err.localizedDescription)")
            if isRunning {
                deliverError(err)
            }
            stopKeepalive()
            ws = nil
            session?.invalidateAndCancel()
            session = nil
            signalFinished()
        }
    }

    private func handleResponseData(_ data: Data) {
        self.lastResponseAt = Date()
        guard let update = parser.ingest(jsonData: data) else {
            return
        }

        if let errMsg = update.errorMessage {
            doushaLog("[SonioxASR] traceId=\(requestId) server error: \(errMsg)")
            deliverError(NSError(domain: "SonioxASR", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: errMsg]))
            signalFinished()
            return
        }

        if update.didProduceContent {
            self.lastTranscriptAt = Date()
            let partial = PartialTranscript(finalText: update.finalText, interimText: update.interimText)
            let cb = onPartial
            DispatchQueue.main.async { cb?(partial) }
        }

        if update.finished {
            doushaLog("[SonioxASR] traceId=\(requestId) finished")
            signalFinished()
        }
    }

    private func signalFinished() {
        finishedChannel?.finish(())
    }

    // MARK: - PCM ingest (audio pushed from the shared AudioTapHub)

    private func appendAndDrainPCM(_ data: Data) async {
        guard isRunning else { return }
        // Async mode never streams PCM — the WAV side-recording is the payload.
        // Skip buffering so a long recording can't grow an unbounded Data.
        guard mode == .realtime else { return }
        totalPcmBytesOut += data.count
        pcmBuffer.append(data)
        try? await flushPendingFrames()
    }

    /// Sends as many complete frames as the buffer holds. No-op until
    /// `canSendAudio` is true (i.e., until the config message has been sent).
    private func flushPendingFrames() async throws {
        guard canSendAudio else { return }
        let frameSize = SonioxConfig.bytesPerFrame
        while pcmBuffer.count >= frameSize {
            let frame = Data(pcmBuffer.prefix(frameSize))
            pcmBuffer.removeFirst(frameSize)
            try await sendAudio(frame)
        }
    }

    /// Flush any remaining sub-frame bytes as a final binary frame (no padding —
    /// Soniox accepts arbitrary-length PCM chunks).
    private func flushLastPartialFrame() async throws {
        guard canSendAudio, !pcmBuffer.isEmpty else { return }
        let frame = Data(pcmBuffer)
        pcmBuffer.removeAll()
        try await sendAudio(frame)
    }

    private func sendAudio(_ frame: Data) async throws {
        guard let ws = ws else { throw URLError(.networkConnectionLost) }
        try await ws.send(.data(frame))
    }

    // MARK: - Helpers

    private func deliverError(_ error: Error) {
        let cb = onError
        DispatchQueue.main.async { cb?(error) }
    }

    private enum WaitOutcome<T: Sendable>: Sendable {
        case signaled(T)
        case timeout
        case cancelled
        case failed
    }

    private func waitWithTimeout<T: Sendable>(channel: OneShotChannel<T>, timeout: TimeInterval) async -> WaitOutcome<T> {
        await withTaskGroup(of: WaitOutcome<T>.self) { group in
            group.addTask {
                do {
                    let v = try await channel.wait()
                    return .signaled(v)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failed
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .timeout
            }
            let first = await group.next() ?? .failed
            group.cancelAll()
            return first
        }
    }
}
