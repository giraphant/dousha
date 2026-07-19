import Foundation
import ConcurrencySupport
import ASRSupport

/// Streaming Doubao IME ASR client. One recording per instance. Audio is pushed
/// in from the shared `AudioTapHub` via `ingest(_:)`: `prepareSession` resets
/// state, `openStream` opens the WebSocket, and `stop()` flushes and receives
/// the final transcript.
///
/// The WebSocket is opened on `openStream()` and closed on `stop()` — matches
/// the Python reference. Reusing the connection across recordings caused
/// Doubao's per-device concurrent quota to fill up after a few fast
/// sessions; the ~600ms TLS+StartTask cost per call is the price.
public actor DoubaoASR {
    private var opusEncoder: OpusEncoder?

    private var session: URLSession?
    private var ws: URLSessionWebSocketTask?

    // State
    private var requestId: String = UUID().uuidString.lowercased()
    private var token: String = ""
    private var deviceId: String = ""

    /// Recognition context hint sent in StartSession `extra.context` to bias the
    /// recognizer toward domain terms / proper nouns (QUA-133). Snapshotted at
    /// `start(contextHint:)` so a Settings change mid-recording can't alter the
    /// active session for the rest of the recording. Empty string = no hint.
    private var contextHint: String = ""
    private var experimentProfile: DoubaoExperimentProfile = .official
    private var pcmBuffer = Data()
    private var didSendFirstFrame = false
    private var canSendAudio = false
    private var resultState = DoubaoResultState()
    private var isRunning = false

    /// Fresh channel per session — recreated in _start() so signals from
    /// previous sessions don't leak forward.
    private var finishedChannel: OneShotChannel<Void>?
    /// Fires once the startup path reaches a terminal state — either StartSession
    /// succeeded (`canSendAudio` flipped true) or `openStream` failed. The stop
    /// path's startup grace waits on this so it wakes the instant the stream
    /// becomes ready, instead of sleeping the full grace on `finishedChannel`
    /// (which only signals on SessionFinished, never on stream-ready).
    private var streamReadyChannel: OneShotChannel<Void>?
    private var didReceiveFinal = false
    private var stopStartedAt: Date?

    /// Flipped true the instant we know the WebSocket is gone — either a
    /// receive-loop failure or a WS-level PING failure (connection abort).
    /// `_stop()` reads it to skip `finishGraceOnStopSeconds`: once the socket is
    /// dead the `SessionFinished` that grace waits for can never arrive, so
    /// burning the full 2s before falling back to a ready engine is pure latency
    /// (QUA-181). Reset per session in `prepareSession`.
    private var wsConnectionDead = false

    /// All PCM that has been (or was attempted to be) streamed to the server this
    /// session, retained so we can replay it on a mid-recording reconnect (QUA-193).
    /// A frame is appended here the instant it's dequeued from `pcmBuffer` —
    /// *before* the send — so audio whose send failed mid-flight is still replayed.
    /// On reconnect it's moved back to the front of `pcmBuffer` and rebuilt as the
    /// fresh session re-streams it. Bounded by recording length (~2 MB/min); a
    /// dictation recording is short enough that a full in-memory replay buffer is
    /// fine, and full replay is the only correct option since Doubao gives us no
    /// way to resume a session mid-stream on a new connection.
    private var retainedPCM = Data()

    /// True while a mid-recording reconnect is in flight. Gates re-entrancy: a
    /// second connection failure during an attempt must not kick off a parallel
    /// reconnect or surface a fatal error — the attempt loop owns the outcome.
    private var isReconnecting = false

    /// Best transcript assembled *before* the current reconnect cleared the live
    /// session state. A reconnect starts a fresh Doubao session (empty transcript)
    /// that re-transcribes the replayed audio; if that fresh session dies early and
    /// produces *less* than we already had, we must not regress. `currentResult()`
    /// returns whichever of {this, the live transcript} is longer — mirroring the
    /// "retranscribe must be strictly longer to win" rule (protocol-notes §3.6).
    private var preReconnectText = ""

    /// One-shot filter used by sendInitialMessages to wait for a specific control
    /// response (TaskStarted/SessionStarted) while the persistent receive loop runs.
    private var pendingResponseFilter: ((AsrResponse) -> Bool)?
    private var pendingResponseChannel: OneShotChannel<AsrResponse>?

    /// Signaled by the receive loop when the WS connection has fully torn down,
    /// so closeWebSocket() can wait for the server's Close ack before invalidating
    /// the URLSession. Keyed by the closing socket's generation so a stale
    /// socket's trailing failure only wakes its own waiter, never a newer
    /// overlapping close's (QUA-130).
    private var wsCloseChannels = GenerationCloseChannels()

    /// Bumped on every openWebSocket() and every closeWebSocket(). The receive
    /// loop captures the value at schedule time and drops any callback whose
    /// generation no longer matches — so when the close handshake runs detached
    /// (off the stop critical path), a stray callback from the socket being
    /// closed can't tear down a freshly-opened session from a new recording.
    private var wsGen = SessionGeneration()

    /// Periodic WebSocket-level PING. Lifecycle is tied to the WS itself: started
    /// in openWebSocket() and cancelled in closeWebSocket() and on receive-loop
    /// failure. The official Doubao IME client sets a 3s ping interval via
    /// SAMICore — without it the server tears down idle sessions, which on a
    /// long recording with mid-sentence pauses manifests as the recording
    /// "getting cut off" before the user finishes.
    private var pingTask: Task<Void, Never>?

    // Callbacks (assigned in prepareSession). Audio level is owned by the
    // AudioTapHub now, so the engine no longer forwards it.
    private var onPartial: (@Sendable (PartialTranscript) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?

    private var framesSentCount = 0
    private var totalPcmBytesOut: Int = 0

    /// When audio capture began for this session. Set in `prepareSession`
    /// (capture itself is owned by the shared `AudioTapHub`); drives the
    /// trace clock in log lines.
    private(set) var audioStartedAt: Date?

    /// Wall-clock of the last server message that carried non-empty transcript
    /// content (`results[].text` non-empty). Feeds the `lastTranscriptAge`
    /// fields in the stop-path log lines.
    private(set) var lastTranscriptAt: Date?

    /// Creates an idle recognizer. No mic access, network, or registration
    /// happens until `prepareSession()` / `openStream()` are called.
    public init() {}

    // MARK: - Lifecycle

    /// Phase 1 — reset session state and mark the engine ready to accept pushed
    /// PCM, without touching the network. `onPartial` is called on the main
    /// queue with the evolving cumulative transcript; `onError` on the main queue
    /// if the WebSocket handshake or ASR session fails (after which you should
    /// still call `stop()` to clean up).
    ///
    /// `MultiEngineBackend` awaits this for
    /// every engine BEFORE starting the shared `AudioTapHub`, so a buffer pushed
    /// the instant the mic goes live can't arrive before `isRunning` flips (which
    /// would drop the opening words). Mic capture + the rolling WAV are now owned
    /// by the hub; audio arrives via `ingest(_:)`.
    ///
    /// - Parameter contextHint: Recognition context (e.g. a glossary of domain
    ///   terms joined into a string) sent in StartSession `extra.context`. Pass
    ///   `""` for none. Snapshotted for the duration of this recording.
    public func prepareSession(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                               onError: @escaping @Sendable (Error) -> Void,
                               contextHint: String = "") {
        guard !isRunning else { return }
        isRunning = true
        self.contextHint = contextHint
        self.experimentProfile = DoubaoExperimentProfile.resolve()
        self.onPartial = onPartial
        self.onError = onError
        self.resultState = DoubaoResultState()
        self.pcmBuffer = Data()
        self.didSendFirstFrame = false
        self.canSendAudio = false
        self.didReceiveFinal = false
        self.stopStartedAt = nil
        self.wsConnectionDead = false
        self.retainedPCM = Data()
        self.isReconnecting = false
        self.preReconnectText = ""
        self.framesSentCount = 0
        self.totalPcmBytesOut = 0
        self.requestId = UUID().uuidString.lowercased()
        self.finishedChannel = OneShotChannel<Void>()
        self.streamReadyChannel = OneShotChannel<Void>()
        self.audioStartedAt = Date()
        self.lastTranscriptAt = nil
        doushaLog("[DoubaoASR] traceId=\(requestId) prepareSession \(experimentProfile.logSummary) (capture owned by AudioTapHub)")
    }

    /// Phase 2 — open the WebSocket and run StartTask/StartSession, then flush
    /// whatever PCM buffered during setup. Fire-and-forget: returns immediately
    /// so the hub's capture (already live) overlaps the ~600ms WS handshake,
    /// with frames accumulating in `pcmBuffer` (`canSendAudio` stays false) until
    /// the session is ready — same "no swallowed opening words" guarantee as the
    /// old mic-first ordering, just with the mic upstream in the hub.
    public nonisolated func openStream() {
        Task { await self._openStream() }
    }

    private func _openStream() async {
        guard isRunning else { return }
        do {
            try await establishSession()

            // Now drain whatever audio accumulated during WS setup.
            self.canSendAudio = true
            self.streamReadyChannel?.finish(())
            try await flushPendingFrames()
        } catch {
            doushaLog("[DoubaoASR] openStream() failed: \(error.localizedDescription)")
            deliverError(error)
            await closeWebSocket()
            isRunning = false
            self.streamReadyChannel?.finish(())
            signalFinished()
        }
    }

    /// Acquires credentials, opens the WebSocket, and runs StartTask/StartSession.
    ///
    /// If the handshake fails, assume Doubao rejected our cached, opaque `app_key`
    /// (QUA-179): the token Doubao hands back is a 10-char `app_key`, not a JWT,
    /// so its expiry can't be checked client-side and a server-invalidated token
    /// would otherwise fail *every* recording until the user manually reset the
    /// credentials. Drop the cached credentials, re-register, and retry the
    /// handshake exactly once before giving up.
    private func establishSession() async throws {
        do {
            try await openAndHandshake()
        } catch {
            guard isRunning else { throw error }
            doushaLog("[DoubaoASR] traceId=\(requestId) handshake failed: \(error.localizedDescription); resetting Doubao credentials and retrying once")
            await closeWebSocket()
            await DoubaoCredentialStore.shared.reset()
            guard isRunning else { throw error }
            try await openAndHandshake()
            doushaLog("[DoubaoASR] traceId=\(requestId) handshake recovered after credential reset")
        }
    }

    private func openAndHandshake() async throws {
        let creds = try await DoubaoCredentialStore.shared.ensureCredentials()
        self.token = creds.token
        self.deviceId = creds.deviceId
        doushaLog("[DoubaoASR] credentials ready device_id=\(creds.deviceId) token_len=\(creds.token.count)")

        self.opusEncoder = try OpusEncoder()
        doushaLog("[DoubaoASR] opus encoder ready")

        // Always a fresh WS: one recording = one connection (ARCHITECTURE §5 —
        // reuse fills Doubao's per-device concurrent quota).
        try openWebSocket()
        doushaLog("[DoubaoASR] websocket opened (fresh)")
        try await sendInitialMessages(deviceId: self.deviceId)
        doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms StartTask+StartSession ok pcmBufferBytes=\(self.pcmBuffer.count)")
    }

    // MARK: - Mid-recording reconnect + replay (QUA-193)

    /// The connection died *during* a recording. Reopen a fresh session and replay
    /// the retained audio, retrying with backoff up to `reconnectMaxAttempts`. On
    /// success the recording continues transparently; if every attempt fails we
    /// fall through to `finalizeConnectionDeath`, which lets `MultiEngine` route to
    /// a co-active engine (Soniox) that already has the full audio.
    ///
    /// Transport-neutral by construction: it drives the handshake + audio replay,
    /// not WS framing — so the future QUIC leg reuses this orchestration unchanged,
    /// swapping only what `openAndHandshake`/`flushPendingFrames` sit on.
    private func attemptReconnectAfterLoss(error: Error) async {
        isReconnecting = true
        // Stop draining onto the (now absent) socket; live audio keeps buffering in
        // pcmBuffer until the fresh session is ready.
        canSendAudio = false
        // Preserve the best transcript we had — the fresh session starts empty and
        // must not be allowed to regress below this if it dies early.
        preReconnectText = longerText(preReconnectText, assembledText())
        doushaLog("[DoubaoASR] traceId=\(requestId) reconnect begin after loss: \(error.localizedDescription) replayBytes=\(retainedPCM.count) preReconnectText.len=\(preReconnectText.count)")

        let attempts = DoubaoConstants.reconnectMaxAttempts
        for attempt in 1...attempts {
            let backoff = DoubaoConstants.reconnectBackoffMs[min(attempt - 1, DoubaoConstants.reconnectBackoffMs.count - 1)]
            try? await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000)
            guard isRunning, stopStartedAt == nil else {
                doushaLog("[DoubaoASR] reconnect aborted before attempt \(attempt) (isRunning=\(isRunning) stopping=\(stopStartedAt != nil))")
                break
            }
            do {
                try await reopenAndReplay()
                isReconnecting = false
                wsConnectionDead = false
                doushaLog("[DoubaoASR] traceId=\(requestId) reconnect SUCCESS on attempt \(attempt) frames=\(framesSentCount) pcmBufferBytes=\(pcmBuffer.count)")
                return
            } catch {
                doushaLog("[DoubaoASR] reconnect attempt \(attempt)/\(attempts) failed: \(error.localizedDescription)")
                await closeWebSocket()
            }
        }

        isReconnecting = false
        doushaLog("[DoubaoASR] traceId=\(requestId) reconnect exhausted — falling back")
        finalizeConnectionDeath(error)
    }

    /// Open a fresh session and replay the full retained recording into it. Doubao
    /// binds a task to a connection, so this is a brand-new session (new requestId)
    /// that re-transcribes the replayed audio from scratch; the live transcript
    /// state is reset and rebuilds as the replay streams.
    private func reopenAndReplay() async throws {
        requestId = UUID().uuidString.lowercased()
        didSendFirstFrame = false
        resultState = DoubaoResultState()

        // Move retained audio to the front of the send buffer so the fresh session
        // replays the whole recording ahead of any live audio that arrived while we
        // were reconnecting. flushPendingFrames re-appends to retainedPCM as it sends.
        if !retainedPCM.isEmpty {
            var replay = retainedPCM
            replay.append(pcmBuffer)
            pcmBuffer = replay
            retainedPCM = Data()
        }

        // openAndHandshake reuses cached creds, opens a fresh WS (ws == nil now),
        // builds a fresh Opus encoder, and runs StartTask + StartSession.
        try await openAndHandshake()

        canSendAudio = true
        try await flushPendingFrames()
        doushaLog("[DoubaoASR] traceId=\(requestId) reconnect replayed pcmBufferBytes=\(pcmBuffer.count) frames=\(framesSentCount)")
    }

    /// Terminal "give up" after a connection loss that couldn't be recovered.
    /// Mirrors the pre-reconnect receive-failure teardown (QUA-181): mark the
    /// connection dead so `_stop()` skips the finish grace, surface the error if
    /// still running, and wake any finish wait.
    private func finalizeConnectionDeath(_ error: Error) {
        wsConnectionDead = true
        if isRunning { deliverError(error) }
        signalFinished()
    }

    private func longerText(_ a: String, _ b: String) -> String { b.count > a.count ? b : a }

    /// Push one chunk of int16 16 kHz mono PCM from the shared `AudioTapHub`.
    /// Replaces the old internal mic-tap callback; buffers until `canSendAudio`,
    /// then streams in Opus frames.
    public nonisolated func ingest(_ pcm: Data) {
        Task { await self.appendAndDrainPCM(pcm) }
    }

    /// Aborts the current recording without sending `FinishSession`, discarding
    /// any pending transcript and the side-recorded WAV. Closes the WebSocket
    /// gracefully so Doubao's per-device concurrent-quota bookkeeping releases
    /// the slot (a hard tear-down here leaves the server still counting us as
    /// active for a while, and the next session fails with `exceedconcurrentquota`).
    ///
    /// Quarantines the live-session callbacks before the close handshake so any
    /// stray server frame that arrives during teardown (e.g., a late TaskFailed)
    /// cannot bleed into AppDelegate's error path and re-trigger UI state.
    ///
    /// Safe to call when not running — returns immediately.
    public nonisolated func cancel() {
        Task { await self._cancel() }
    }

    private func _cancel() async {
        doushaLog("[DoubaoASR] cancel() isRunning=\(isRunning)")
        guard isRunning else { return }
        isRunning = false

        // Quarantine callbacks FIRST so the close handshake can't deliver a
        // stale error/partial up the stack.
        self.onPartial = nil
        self.onError = nil

        // Mic capture + the shared WAV are owned by the AudioTapHub, which the
        // coordinator cancels separately — nothing to tear down here.

        // Graceful WS close — sends Normal Closure (1000) and waits for the
        // server's ack so Doubao's concurrent-session counter clears promptly.
        await closeWebSocket()

        signalFinished()
        doushaLog("[DoubaoASR] cancel() done")
    }

    /// Stops capturing the microphone, sends `FinishSession`, and waits up to
    /// 2.5 s for the server to flush its final transcript.
    ///
    /// - Parameter completion: Called on the main queue with the final
    ///   transcript (assembled from all VAD-finalized segments plus the last
    ///   interim). Will be called exactly once. Empty string is possible if
    ///   the user released before producing any speech, or if `start()` never
    ///   reached the streaming phase.
    ///
    /// Safe to call when not running — completion fires with whatever was
    /// already captured.
    public nonisolated func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        Task {
            let result = await self._stop()
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func _stop() async -> TranscriptionResult {
        doushaLog("[DoubaoASR] stop() isRunning=\(isRunning)")
        guard isRunning else {
            return TranscriptionResult(text: bestText(), traceId: requestId)
        }
        let stopStartedAt = Date()
        self.stopStartedAt = stopStartedAt
        let transcriptAgeAtStop = lastTranscriptAt.map { Int(stopStartedAt.timeIntervalSince($0) * 1000) } ?? -1
        doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs(now: stopStartedAt))ms stop begin lastTranscriptAge=\(transcriptAgeAtStop)ms frames=\(framesSentCount) pcmBufferBytes=\(pcmBuffer.count)")
        // The shared AudioTapHub has already removed the mic tap and held its own
        // drain window before calling us, so no new audio is arriving. But the
        // tap dispatched the last buffers the user spoke as separate Tasks into
        // this actor (ingest → appendAndDrainPCM); some may still be queued ahead
        // of nothing — yield a few times so they land in pcmBuffer before we flip
        // isRunning=false (which would otherwise drop them via the ingest guard,
        // truncating the final word). Draining is what preserves the tail.
        for _ in 0..<4 { await Task.yield() }
        doushaLog("[DoubaoASR] traceId=\(requestId) stop+\(elapsedMs(since: stopStartedAt))ms actor-drain-yield done pcmBufferBytes=\(pcmBuffer.count)")
        isRunning = false

        if !streamReady {
            // We are abandoning the startup path unless it becomes ready within
            // the short grace below. Quarantine callbacks so a late URLSession
            // timeout cannot turn a successful fallback into a UI error.
            onPartial = nil
            onError = nil

            let sessionAge = audioStartedAt.map { stopStartedAt.timeIntervalSince($0) } ?? 0
            let remainingGrace = max(0, DoubaoConstants.startupGraceOnStopSeconds - sessionAge)
            if remainingGrace > 0, let channel = streamReadyChannel {
                doushaLog("[DoubaoASR] traceId=\(requestId) stop+\(elapsedMs(since: stopStartedAt))ms stream not ready; waiting startup grace \(Int(remainingGrace * 1000))ms")
                _ = await channel.wait(timeout: remainingGrace)
            }

            if !streamReady {
                let result = currentResult()
                doushaLog("[DoubaoASR] traceId=\(requestId) stop+\(elapsedMs(since: stopStartedAt))ms stream not ready after startup grace; skip FinishSession and return text.len=\(result.text.count) frames=\(framesSentCount) pcmBufferBytes=\(pcmBuffer.count)")
                detachAndCloseWebSocketInBackground()
                return result
            }
        }

        // Drain ALL pending frames. flushPendingFrames is load-bearing here —
        // flushAndSendLastFrame alone would only handle the very last partial
        // frame.
        do {
            let beforeFlush = Date()
            try await flushPendingFrames()
            doushaLog("[DoubaoASR] traceId=\(requestId) stop+\(elapsedMs(since: stopStartedAt))ms flushPending done duration=\(elapsedMs(since: beforeFlush))ms frames=\(framesSentCount) pcmBufferBytes=\(pcmBuffer.count)")

            let beforeLast = Date()
            try await flushAndSendLastFrame()
            doushaLog("[DoubaoASR] traceId=\(requestId) stop+\(elapsedMs(since: stopStartedAt))ms lastFrame done duration=\(elapsedMs(since: beforeLast))ms frames=\(framesSentCount) pcmBufferBytes=\(pcmBuffer.count)")

            let beforeFinish = Date()
            try await sendFinishSession()
            doushaLog("[DoubaoASR] traceId=\(requestId) stop+\(elapsedMs(since: stopStartedAt))ms FinishSession sent duration=\(elapsedMs(since: beforeFinish))ms")
        } catch {
            doushaLog("[DoubaoASR] traceId=\(requestId) stop+\(elapsedMs(since: stopStartedAt))ms stop send error: \(error.localizedDescription)")
        }

        // Wait for SessionFinished, but only briefly. This is NOT the official
        // client's finish_wait_timeout=10000 "drain the whole backlog" wait — by
        // the time we send FinishSession the partials are already assembled, so
        // we only need a quick confirmation that the server agrees the session is
        // done. If SessionFinished doesn't arrive within finishGraceOnStopSeconds
        // we treat the session as failed and return an empty result, letting
        // MultiEngine fall back to a backup engine (which re-runs the retained
        // audio) instead of blocking the paste on a slow tail.
        let waitStart = Date()
        let outcomeStr: String
        if wsConnectionDead {
            // The WS is already known dead (ping/receive failure) — SessionFinished
            // can never arrive, so don't wait the grace. Fall through to the
            // empty-result path below so MultiEngine falls back to a ready engine
            // immediately instead of blocking ~2s (QUA-181).
            outcomeStr = "ws-dead"
        } else if let channel = finishedChannel {
            switch await channel.wait(timeout: DoubaoConstants.finishGraceOnStopSeconds) {
            // A dead-connection signal racing the wait (ping/receive failure fires
            // signalFinished while we're parked) wakes us as .signaled — re-check
            // the flag so we still take the fallback path, not the success path.
            case .signaled: outcomeStr = wsConnectionDead ? "ws-dead" : "signaled"
            case .timeout: outcomeStr = "timedOut"
            case .cancelled: outcomeStr = "cancelled"
            case .failed: outcomeStr = "failed"
            }
        } else {
            outcomeStr = "no-channel"
        }
        doushaLog("[DoubaoASR] traceId=\(requestId) stop+\(elapsedMs(since: stopStartedAt))ms post-Finish wait \(Int(Date().timeIntervalSince(waitStart) * 1000))ms result=\(outcomeStr)")

        if outcomeStr != "signaled" {
            let partialLen = assembledText().count
            let finalTranscriptAge = lastTranscriptAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
            doushaLog("[DoubaoASR] traceId=\(requestId) stop+\(elapsedMs(since: stopStartedAt))ms SessionFinished missing (outcome=\(outcomeStr)); returning empty result partial.len=\(partialLen) segments=\(resultState.committedSegments.count) lastTranscriptAge=\(finalTranscriptAge)ms")
            detachAndCloseWebSocketInBackground()
            return TranscriptionResult(text: "", traceId: requestId)
        }

        let final = assembledText()
        let finalTranscriptAge = lastTranscriptAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
        doushaLog("[DoubaoASR] traceId=\(requestId) stop+\(elapsedMs(since: stopStartedAt))ms stop final text.len=\(final.count) segments=\(resultState.committedSegments.count) lastTranscriptAge=\(finalTranscriptAge)ms")

        let result = currentResult()
        // Close the WebSocket after every session (see class doc), but off the
        // critical path — the transcript is already assembled, so the caller
        // gets it NOW instead of waiting on the up-to-1s close handshake. We
        // unhook the socket/session from actor state SYNCHRONOUSLY here so a
        // fast restart can't be clobbered by the trailing close.
        detachAndCloseWebSocketInBackground()
        return result
    }

    /// Synchronously unhooks the current socket/session from actor state and
    /// bumps the generation, then runs the up-to-1s WS close handshake in a
    /// detached task. Clearing `self.ws`/`self.session` before
    /// returning means a reentrant `_start()` that opens a fresh socket can't be
    /// torn down by the trailing close — the handshake uses only the captured
    /// handles.
    private func detachAndCloseWebSocketInBackground() {
        stopPingLoop()
        guard let closing = ws else {
            session?.invalidateAndCancel()
            session = nil
            return
        }
        let closingSession = session
        // The socket's receive loop runs under the current generation; register
        // the close channel under it BEFORE the bump so the socket's own failure
        // callback (which fires with that generation) wakes this waiter.
        let closingGeneration = wsGen.live
        self.ws = nil
        self.session = nil
        _ = wsGen.bump()

        let channel = wsCloseChannels.register(closingGeneration)
        closing.cancel(with: .normalClosure, reason: nil)
        Task {
            if case .timeout = await channel.wait(timeout: 1.0) {
                doushaLog("[DoubaoASR] WS close handshake timed out — tearing down anyway")
            }
            self.wsCloseChannels.remove(closingGeneration)
            closingSession?.invalidateAndCancel()
        }
    }

    private func closeWebSocket() async {
        stopPingLoop()
        guard let ws = ws else {
            session?.invalidateAndCancel()
            session = nil
            return
        }
        // Drop our reference first so the receive loop's success branch stops
        // rescheduling itself if a stray message arrives during the close handshake.
        self.ws = nil
        // Register the close channel under the socket's current generation
        // BEFORE the bump so its own failure callback wakes this waiter.
        let closingGeneration = wsGen.live
        // Invalidate this socket's receive callbacks NOW (before awaiting the
        // close handshake). This close may run detached off the stop path, so a
        // fresh _start() could open a new socket during the await — bumping the
        // generation keeps the old socket's trailing failure from tearing it down.
        _ = wsGen.bump()
        // Capture the session this close owns; a reentrant _start() during the
        // await may replace self.session, and we must only tear down our own.
        let owningSession = session

        let channel = wsCloseChannels.register(closingGeneration)

        // Send a WS Close frame (1000 Normal Closure). The server replies with its
        // own Close frame, which surfaces as a .failure on the receive loop and
        // signals this generation's close channel.
        ws.cancel(with: .normalClosure, reason: nil)

        if case .timeout = await channel.wait(timeout: 1.0) {
            doushaLog("[DoubaoASR] WS close handshake timed out — tearing down anyway")
        }
        wsCloseChannels.remove(closingGeneration)

        owningSession?.invalidateAndCancel()
        // Only clear shared state if a reentrant reopen hasn't already replaced
        // the session — otherwise we'd kill the new recording's connection.
        if session === owningSession {
            session = nil
        }
    }

    // MARK: - WebSocket

    private func openWebSocket() throws {
        var components = URLComponents(string: DoubaoConstants.websocketURL)!
        components.queryItems = [
            URLQueryItem(name: "aid", value: String(DoubaoConstants.aid)),
            URLQueryItem(name: "device_id", value: deviceId)
        ]
        var req = URLRequest(url: components.url!)
        req.setValue(DoubaoConstants.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("v2", forHTTPHeaderField: "proto-version")
        req.setValue("true", forHTTPHeaderField: "x-custom-keepalive")

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        let sess = URLSession(configuration: cfg)
        self.session = sess
        self.ws = sess.webSocketTask(with: req)
        self.ws?.resume()
        // The receive loop is shared across all sessions on this connection.
        startReceiveLoop(generation: wsGen.bump())
        startPingLoop()
    }

    private func startPingLoop() {
        pingTask?.cancel()
        let intervalNs = UInt64(DoubaoConstants.websocketPingIntervalSeconds * 1_000_000_000)
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                if Task.isCancelled { return }
                await self?.sendKeepalivePing()
            }
        }
    }

    private func stopPingLoop() {
        pingTask?.cancel()
        pingTask = nil
    }

    /// Fire-and-forget WS-level PING. URLSessionWebSocketTask calls the pong
    /// handler when the server replies (or with an error if the WS is dead);
    /// we only log on error — the receive loop is the canonical "WS died"
    /// signal, this is just for visibility.
    private func sendKeepalivePing() {
        guard let ws = ws else { return }
        let generation = wsGen.live
        ws.sendPing { [weak self] error in
            if let error = error {
                doushaLog("[DoubaoASR] ws ping failed: \(error.localizedDescription)")
                Task { await self?.notePingFailure(generation: generation) }
            }
        }
    }

    /// A WS-level PING failed — the connection is dead (often half-open: the
    /// outbound ping errors instantly while the pending `receive` callback sits
    /// for far longer than the finish grace). Mark the socket dead and wake any
    /// in-flight finish wait so `_stop()` falls back to a ready engine NOW
    /// instead of burning `finishGraceOnStopSeconds` waiting for a
    /// `SessionFinished` that can never arrive (QUA-181). We deliberately do NOT
    /// tear the socket down here — the receive loop stays the canonical teardown
    /// path; this only flips the fast-fail flag and signals the channel.
    private func notePingFailure(generation: Generation) {
        guard wsGen.isCurrent(generation) else { return }
        guard !wsConnectionDead else { return }
        if isRunning, stopStartedAt == nil, !isReconnecting {
            // Mid-recording half-open connection: the pending `receive` callback can
            // sit far longer than we'd want to wait. Cancel the socket so the
            // receive loop fails *now* and routes into the reconnect path (QUA-193),
            // instead of stalling until the OS TCP timeout.
            doushaLog("[DoubaoASR] ping failed mid-recording — cancelling socket to trigger fast reconnect")
            ws?.cancel(with: .abnormalClosure, reason: nil)
            return
        }
        wsConnectionDead = true
        signalFinished()
    }

    private func sendInitialMessages(deviceId: String) async throws {
        // StartTask once per WebSocket (Doubao binds task to connection); every
        // recording opens a fresh WS, so this always runs exactly once.
        try await sendData(AsrMessageBuilder.startTask(requestId: requestId, token: token))
        let resp = try await waitForResponse(timeout: 5.0) {
            $0.messageType == "TaskStarted" || $0.messageType == "TaskFailed" || $0.messageType == "SessionFailed"
        }
        doushaLog("[DoubaoASR] StartTask resp messageType=\(resp.messageType) code=\(resp.statusCode) msg=\(resp.statusMessage)")
        if resp.messageType != "TaskStarted" {
            throw NSError(domain: "DoubaoASR", code: Int(resp.statusCode),
                          userInfo: [NSLocalizedDescriptionKey: "StartTask: \(resp.statusMessage.isEmpty ? "failed" : resp.statusMessage) (\(resp.statusCode))"])
        }

        let configJSON = sessionConfigJSON(deviceId: deviceId)
        if contextHint.isEmpty {
            doushaLog("[DoubaoASR] StartSession context: (none)")
        } else {
            let preview = contextHint.count > 60 ? String(contextHint.prefix(60)) + "…" : contextHint
            doushaLog("[DoubaoASR] StartSession context.len=\(contextHint.count) preview=\(preview)")
        }
        try await sendData(AsrMessageBuilder.startSession(requestId: requestId, token: token, configJSON: configJSON))
        let resp2 = try await waitForResponse(timeout: 5.0) {
            $0.messageType == "SessionStarted" || $0.messageType == "TaskFailed" || $0.messageType == "SessionFailed"
        }
        doushaLog("[DoubaoASR] StartSession resp messageType=\(resp2.messageType) code=\(resp2.statusCode) msg=\(resp2.statusMessage)")
        if resp2.messageType != "SessionStarted" {
            throw NSError(domain: "DoubaoASR", code: Int(resp2.statusCode),
                          userInfo: [NSLocalizedDescriptionKey: "StartSession: \(resp2.statusMessage.isEmpty ? "failed" : resp2.statusMessage) (\(resp2.statusCode))"])
        }
    }

    /// Suspend until `handleResponseData` sees a response matching `predicate`,
    /// or until `timeout` elapses. Used by sendInitialMessages so we can keep a
    /// single shared receive loop running on the WebSocket.
    private func waitForResponse(timeout: TimeInterval, where predicate: @escaping (AsrResponse) -> Bool) async throws -> AsrResponse {
        let channel = OneShotChannel<AsrResponse>(AsrResponse.self)
        pendingResponseFilter = predicate
        pendingResponseChannel = channel

        let outcome = await channel.wait(timeout: timeout)
        pendingResponseFilter = nil
        pendingResponseChannel = nil

        switch outcome {
        case .signaled(let r): return r
        case .timeout: throw URLError(.timedOut)
        case .cancelled, .failed: throw URLError(.cannotParseResponse)
        }
    }

    /// Wire audio format: 10ms frames encoded to opus (official-client parity).
    static let wireFormat = "speech_opus"

    private func sessionConfigJSON(deviceId: String) -> String {
        buildSessionConfigJSON(deviceId: deviceId, contextHint: contextHint, profile: experimentProfile, audioFormat: Self.wireFormat)
    }

    private func sendFinishSession() async throws {
        try await sendData(AsrMessageBuilder.finishSession(requestId: requestId, token: token))
    }

    private func sendData(_ data: Data) async throws {
        guard let ws = ws else { throw URLError(.networkConnectionLost) }
        try await ws.send(.data(data))
    }

    private func startReceiveLoop(generation: Generation) {
        guard let ws = ws else { return }
        ws.receive { [weak self] result in
            // Bridge URLSession's delegate-queue callback into the actor.
            Task { await self?.handleReceiveResult(result, generation: generation) }
        }
    }

    private func handleReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, Error>, generation: Generation) async {
        switch result {
        case .success(let msg):
            // Drop content from a socket that has since been replaced/closed so
            // a trailing frame can't mutate a fresh session's state.
            guard wsGen.isCurrent(generation) else { return }
            let data: Data
            switch msg {
            case .data(let d):   data = d
            case .string(let s): data = Data(s.utf8)
            @unknown default:    data = Data()
            }
            if !data.isEmpty {
                handleResponseData(data)
            }
            // Keep listening as long as the WebSocket is alive.
            if self.ws != nil {
                startReceiveLoop(generation: generation)
            }
        case .failure(let err):
            // Signal the close handshake BEFORE the generation guard: when
            // closeWebSocket() bumps wsGen and cancels the socket, this
            // failure callback is what wakes the close-await. Gating it behind
            // the guard would make every close block the full 1s timeout. Keying
            // by this callback's own generation ensures a stale socket can't
            // wake a newer close.
            wsCloseChannels.signal(generation)
            // A stale-generation failure (the socket closeWebSocket() is tearing
            // down) must not touch the live session — return after signaling.
            guard wsGen.isCurrent(generation) else { return }
            doushaLog("[DoubaoASR] receive failed: \(err.localizedDescription)")
            // Drop the dead socket's references so a reopen starts clean. This is
            // done unconditionally — whether we reconnect or fall back, the socket
            // that just failed is gone.
            stopPingLoop()
            ws = nil
            session?.invalidateAndCancel()
            session = nil
            pendingResponseFilter = nil
            // Unblock any handshake wait in flight (e.g. a reconnect attempt that
            // was mid-StartTask when this socket failed) so it can retry/abort.
            pendingResponseChannel?.finish(throwing: CancellationError())
            pendingResponseChannel = nil

            if isRunning, stopStartedAt == nil, !isReconnecting {
                // Mid-recording connection death — try to reopen + replay the
                // retained audio before giving up (QUA-193). The attempt loop owns
                // the terminal outcome (success → resume; exhausted → fall back).
                await attemptReconnectAfterLoss(error: err)
            } else if isReconnecting {
                // A failure during an in-flight reconnect attempt: the attempt's
                // handshake wait was just unblocked above, so its `do/catch` drives
                // the retry. Don't mark dead or deliver an error here.
                doushaLog("[DoubaoASR] receive failed during reconnect attempt — letting attempt loop retry")
            } else {
                // Not mid-recording (stopping / cancelled / not running): behave as
                // before. Known-dead lets _stop() skip the finish grace (QUA-181).
                wsConnectionDead = true
                if isRunning { deliverError(err) }
                signalFinished()
            }
        }
    }

    private func handleResponseData(_ data: Data) {
        guard let resp = try? AsrResponse.decode(data) else {
            doushaLog("[DoubaoASR] recv: decode failed (\(data.count) bytes)")
            return
        }
        doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms recv messageType=\(resp.messageType) code=\(resp.statusCode) jsonLen=\(resp.resultJson.count)")
        if let stopStartedAt {
            doushaLog("[DoubaoASR] traceId=\(requestId) stop+\(elapsedMs(since: stopStartedAt))ms recv-after-stop messageType=\(resp.messageType) code=\(resp.statusCode) jsonLen=\(resp.resultJson.count)")
        }

        // Drop responses for prior (closed) sessions on this reused WebSocket. Server
        // echoes our request_id; if it doesn't match the current session, it's stale.
        if !resp.requestId.isEmpty && !self.requestId.isEmpty && resp.requestId != self.requestId {
            doushaLog("[DoubaoASR] dropping stale (current=\(self.requestId))")
            return
        }

        // sendInitialMessages waits for a specific control response — if this matches,
        // hand it back and skip the streaming-result handling below.
        if let pred = pendingResponseFilter, pred(resp) {
            pendingResponseFilter = nil
            pendingResponseChannel?.finish(resp)
            pendingResponseChannel = nil
            return
        }

        switch resp.messageType {
        case "SessionFinished":
            doushaLog("[DoubaoASR] SessionFinished code=\(resp.statusCode)")
            signalFinished()
            return
        case "TaskFailed", "SessionFailed":
            doushaLog("[DoubaoASR] \(resp.messageType) statusCode=\(resp.statusCode) statusMessage=\(resp.statusMessage) resultJson=\(resp.resultJson)")
            let msg = resp.statusMessage.isEmpty ? "ASR failed (\(resp.statusCode))" : "\(resp.statusMessage) (\(resp.statusCode))"
            deliverError(NSError(domain: "DoubaoASR", code: Int(resp.statusCode),
                                  userInfo: [NSLocalizedDescriptionKey: msg]))
            signalFinished()
            return
        default:
            break
        }

        guard let update = resultState.ingest(resultJson: resp.resultJson) else { return }
        self.lastTranscriptAt = Date()

        let preview = update.text.prefix(40).replacingOccurrences(of: "\n", with: " ")
        let stopDelta = stopStartedAt.map { " stop+\(elapsedMs(since: $0))ms" } ?? ""
        doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms\(stopDelta) result isInterim=\(update.isInterim) vadFinished=\(update.vadFinished) nonstream=\(update.nonstreamResult) textLen=\(update.text.count) currentInterimLen=\(update.previousInterimLength) newUtterance=\(update.looksLikeNewUtterance) preview=\(preview)")

        switch update.commit {
        case .rescued(let rescued):
            doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms segment rescued index=\(resultState.committedSegments.count) text.len=\(rescued.count) newText.len=\(update.text.count)")
        case .final(let text):
            doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms segment final index=\(resultState.committedSegments.count) text.len=\(text.count)")
        case nil:
            break
        }

        let cb = onPartial
        DispatchQueue.main.async { cb?(update.partial) }
    }

    private var streamReady: Bool {
        canSendAudio || framesSentCount > 0
    }

    private func assembledText() -> String {
        resultState.displayText
    }

    /// The transcript to hand back: the longer of the live session text and any
    /// text preserved from before a reconnect (QUA-193). Without a reconnect,
    /// `preReconnectText` is empty so this is just `assembledText()`.
    private func bestText() -> String {
        longerText(preReconnectText, assembledText())
    }

    private func currentResult() -> TranscriptionResult {
        TranscriptionResult(text: bestText(), traceId: requestId)
    }

    private func traceElapsedMs(now: Date = Date()) -> Int {
        guard let audioStartedAt else { return 0 }
        return Int(now.timeIntervalSince(audioStartedAt) * 1000)
    }

    private func elapsedMs(since start: Date, now: Date = Date()) -> Int {
        Int(now.timeIntervalSince(start) * 1000)
    }

    private func signalFinished() {
        finishedChannel?.finish(())
    }

    // MARK: - PCM ingest (audio pushed from the shared AudioTapHub)

    private func appendAndDrainPCM(_ data: Data) async {
        guard isRunning else { return }
        totalPcmBytesOut += data.count
        pcmBuffer.append(data)
        try? await flushPendingFrames()
    }

    /// Sends as many complete frames (`Constants.bytesPerFrame`) as the buffer
    /// holds. No-op until
    /// `canSendAudio` is true (i.e., until StartSession has succeeded).
    ///
    /// Each dequeued frame is appended to `retainedPCM` *before* the send so it can
    /// be replayed on a mid-recording reconnect even if this very send fails
    /// (QUA-193). On a send failure we cancel the socket — that surfaces as a
    /// receive-loop failure which routes into the reconnect/fallback path — and
    /// rethrow so a replay-in-progress reconnect attempt fails fast and retries.
    private func flushPendingFrames() async throws {
        guard canSendAudio else { return }
        let frameSize = DoubaoConstants.bytesPerFrame
        while pcmBuffer.count >= frameSize {
            let frame = Data(pcmBuffer.prefix(frameSize))
            pcmBuffer.removeFirst(frameSize)
            retainedPCM.append(frame)
            let state: FrameState = didSendFirstFrame ? .middle : .first
            do {
                try await encodeAndSend(frame, state: state)
            } catch {
                doushaLog("[DoubaoASR] encodeAndSend error: \(error.localizedDescription); cancelling socket to trigger reconnect/fallback")
                ws?.cancel(with: .abnormalClosure, reason: nil)
                throw error
            }
            didSendFirstFrame = true
            framesSentCount += 1
            if framesSentCount == 1 || framesSentCount % 100 == 0 {
                doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms sent frame state=\(state.rawValue) frames=\(framesSentCount) pcmBytesOut=\(totalPcmBytesOut) pcmBufferBytes=\(pcmBuffer.count)")
            }
        }
    }

    private func flushAndSendLastFrame() async throws {
        doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms flushLast framesSent=\(framesSentCount) pcmBufferRemaining=\(pcmBuffer.count) didSendFirst=\(didSendFirstFrame) totalPcmBytesOut=\(totalPcmBytesOut)")
        let frameSize = DoubaoConstants.bytesPerFrame
        if pcmBuffer.isEmpty {
            // Still need a LAST marker if any frames were sent.
            if didSendFirstFrame {
                let silent = Data(count: frameSize)
                try await encodeAndSend(silent, state: .last)
                doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms sent LAST silent")
            }
            return
        }
        // Pad final partial frame with zeros.
        if pcmBuffer.count < frameSize {
            pcmBuffer.append(Data(count: frameSize - pcmBuffer.count))
        }
        let frame = Data(pcmBuffer.prefix(frameSize))
        pcmBuffer.removeAll()
        try await encodeAndSend(frame, state: .last)
        doushaLog("[DoubaoASR] traceId=\(requestId) t=\(traceElapsedMs())ms sent LAST frame")
    }

    private func encodeAndSend(_ pcmFrame: Data, state: FrameState) async throws {
        // The nil-guard semantics are load-bearing — encoder is always set
        // after establishSession; a nil here means a frame raced a teardown
        // and must be dropped, not sent raw.
        guard let encoder = opusEncoder else { return }
        let payload = try encoder.encode(pcmFrame)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let msg = AsrMessageBuilder.taskRequest(
            audio: payload,
            requestId: requestId,
            frameState: state,
            timestampMs: now
        )
        try await sendData(msg)
    }

    // MARK: - Helpers

    private func deliverError(_ error: Error) {
        let cb = onError
        DispatchQueue.main.async { cb?(error) }
    }

}
