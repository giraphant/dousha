import Foundation
import AVFoundation
import TalkerCommonSync

/// Streaming Doubao IME ASR client. One recording per instance:
/// call `start()` to begin capturing the mic and streaming to Doubao,
/// then `stop()` to flush and receive the final transcript.
///
/// The WebSocket is opened on `start()` and closed on `stop()` — matches
/// the Python reference. Reusing the connection across recordings caused
/// Doubao's per-device concurrent quota to fill up after a few fast
/// sessions; the ~600ms TLS+StartTask cost per call is the price.
public actor DoubaoASR {
    private let audioEngine = AVAudioEngine()
    private var pcmConverter: AVAudioConverter?
    private var pcmTargetFormat: AVAudioFormat?
    private var opusEncoder: OpusEncoder?

    private var session: URLSession?
    private var ws: URLSessionWebSocketTask?

    // State
    private var requestId: String = UUID().uuidString.lowercased()
    private var token: String = ""
    private var deviceId: String = ""
    private var pcmBuffer = Data()
    private var didSendFirstFrame = false
    private var canSendAudio = false
    /// VAD-finalized utterances within this recording session, in order.
    private var committedSegments: [String] = []
    /// Latest interim text for the *current* (not-yet-finalized) utterance.
    private var currentInterim: String = ""
    private var isRunning = false

    /// Fresh channel per session — recreated in _start() so signals from
    /// previous sessions don't leak forward.
    private var finishedChannel: OneShotChannel<Void>?
    private var didReceiveFinal = false

    /// Whether StartTask has been sent + acked on the current WebSocket. Doubao ties a
    /// task to a connection — sending StartTask twice on the same WS yields
    /// "task already started". Currently we close the WS after every stop() so this
    /// flag always resets to false, but the gate is kept so future re-enabling of WS
    /// reuse can flip it back on without reintroducing the bug.
    private var taskStarted: Bool = false

    /// One-shot filter used by sendInitialMessages to wait for a specific control
    /// response (TaskStarted/SessionStarted) while the persistent receive loop runs.
    private var pendingResponseFilter: ((AsrResponse) -> Bool)?
    private var pendingResponseChannel: OneShotChannel<AsrResponse>?

    /// Signaled by the receive loop when the WS connection has fully torn down,
    /// so closeWebSocket() can wait for the server's Close ack before invalidating
    /// the URLSession.
    private var wsClosedChannel: OneShotChannel<Void>?

    /// Periodic WebSocket-level PING. Lifecycle is tied to the WS itself: started
    /// in openWebSocket() and cancelled in closeWebSocket() and on receive-loop
    /// failure. The official Doubao IME client sets a 3s ping interval via
    /// SAMICore — without it the server tears down idle sessions, which on a
    /// long recording with mid-sentence pauses manifests as the recording
    /// "getting cut off" before the user finishes.
    private var pingTask: Task<Void, Never>?

    // Callbacks (assigned in start)
    private var onPartial: (@Sendable (String) -> Void)?
    private var onAudioLevel: (@Sendable (Float) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?

    private var framesSentCount = 0
    private var totalPcmBytesOut: Int = 0

    // WAV side-recording for fallback re-transcription on WS drops.
    // The writer is held as a const-after-init local in startMicTap so the audio
    // tap closure (which is non-isolated and runs on the audio thread) can call
    // .append() directly without hopping into the actor. The actor's reference
    // is just for close() during _stop().
    private var wavWriter: WavFileWriter?
    private(set) var audioStartedAt: Date?

    /// Wall-clock timestamps of every VAD-finalized segment commit during this
    /// recording. Used by the detector to spot large gaps that indicate Doubao
    /// silently dropped a chunk of audio mid-recording.
    private(set) var segmentCommittedAt: [Date] = []

    /// Any byte from the server (heartbeats included). For debugging "is the WS
    /// alive at all" — NOT the heuristic's staleness signal (heartbeats would mask
    /// real drops). See `lastTranscriptAt` for that.
    private(set) var lastResponseAt: Date?

    /// Wall-clock of the last server message that carried non-empty transcript
    /// content (`results[].text` non-empty). This is what the incomplete-detector
    /// looks at to decide "did the server stop producing text long before the
    /// user released?".
    private(set) var lastTranscriptAt: Date?

    /// Path where the rolling per-session WAV gets written.
    public static var savedAudioURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dousha", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last_recording.wav")
    }

    /// Creates an idle recognizer. No mic access, network, or registration
    /// happens until `start()` is called.
    public init() {}

    // MARK: - Lifecycle

    /// Begins capturing the microphone and streaming audio to Doubao.
    ///
    /// - Parameters:
    ///   - onPartial: Called on the main queue with the live transcript as it
    ///     evolves. Includes both VAD-finalized segments and the in-progress
    ///     interim text. May be called many times per second; updates are
    ///     cumulative (not deltas).
    ///   - onAudioLevel: Called on the main queue with a 0...1 RMS level
    ///     suitable for driving a waveform UI.
    ///   - onError: Called on the main queue if registration, the WebSocket
    ///     handshake, or the ASR session fails. After an error you should
    ///     still call `stop()` to clean up.
    ///
    /// Calling `start()` while already running is a no-op.
    public nonisolated func start(onPartial: @escaping @Sendable (String) -> Void,
                                  onAudioLevel: @escaping @Sendable (Float) -> Void,
                                  onError: @escaping @Sendable (Error) -> Void) {
        Task { await self._start(onPartial: onPartial, onAudioLevel: onAudioLevel, onError: onError) }
    }

    private func _start(onPartial: @escaping @Sendable (String) -> Void,
                        onAudioLevel: @escaping @Sendable (Float) -> Void,
                        onError: @escaping @Sendable (Error) -> Void) async {
        guard !isRunning else { return }
        isRunning = true
        self.onPartial = onPartial
        self.onAudioLevel = onAudioLevel
        self.onError = onError
        self.committedSegments = []
        self.currentInterim = ""
        self.segmentCommittedAt = []
        self.pcmBuffer = Data()
        self.didSendFirstFrame = false
        self.canSendAudio = false
        self.didReceiveFinal = false
        self.framesSentCount = 0
        self.totalPcmBytesOut = 0
        self.requestId = UUID().uuidString.lowercased()
        self.finishedChannel = OneShotChannel<Void>()
        self.audioStartedAt = nil
        self.lastResponseAt = nil
        self.lastTranscriptAt = nil
        self.wavWriter = nil

        doushaLog("[DoubaoASR] start() requestId=\(requestId)")

        do {
            let creds = try await DoubaoCredentialStore.shared.ensureCredentials()
            self.token = creds.token
            self.deviceId = creds.deviceId
            doushaLog("[DoubaoASR] credentials ready device_id=\(creds.deviceId) token_len=\(creds.token.count)")

            self.opusEncoder = try OpusEncoder()
            doushaLog("[DoubaoASR] opus encoder ready")

            // Open the rolling WAV before the mic tap so that startMicTap can
            // snapshot the writer reference into the tap closure.
            do {
                // Remove any prior file so AVAudioFile's "no overwrite" semantics don't bite us.
                try? FileManager.default.removeItem(at: Self.savedAudioURL)
                self.wavWriter = try WavFileWriter(
                    url: Self.savedAudioURL,
                    sampleRate: DoubaoConstants.sampleRate,
                    channels: DoubaoConstants.channels
                )
                self.audioStartedAt = Date()
                doushaLog("[DoubaoASR] WAV side-recording opened at \(Self.savedAudioURL.path)")
            } catch {
                doushaLog("[DoubaoASR] WAV writer failed to open: \(error.localizedDescription) — continuing without side recording")
                self.wavWriter = nil
            }

            // Start mic FIRST so audio buffers while we set up the WebSocket.
            // Doubao kills sessions that go ~900ms without audio after StartSession.
            // (Must come after wavWriter is assigned so startMicTap can snapshot it.)
            try startMicTap()
            doushaLog("[DoubaoASR] mic tap started (pre-WS)")

            if self.ws == nil {
                try openWebSocket()
                doushaLog("[DoubaoASR] websocket opened (fresh)")
            } else {
                doushaLog("[DoubaoASR] reusing existing websocket")
            }
            try await sendInitialMessages(deviceId: self.deviceId)
            doushaLog("[DoubaoASR] StartTask + StartSession both succeeded; pcmBufferBytes=\(self.pcmBuffer.count)")

            // Now drain whatever audio accumulated during WS setup.
            self.canSendAudio = true
            try await flushPendingFrames()
        } catch {
            doushaLog("[DoubaoASR] start() failed: \(error.localizedDescription)")
            deliverError(error)
            await closeWebSocket()
            teardownAudio()
            if let writer = self.wavWriter {
                try? writer.close()
                self.wavWriter = nil
            }
            isRunning = false
            signalFinished()
        }
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
        self.onAudioLevel = nil
        self.onError = nil

        teardownAudio()

        // Close & delete the WAV. close() is a barrier on the writer's serial
        // queue; calling it ensures any in-flight append from the mic tap is
        // flushed before we remove the file. Without this you can race with the
        // tap's dispatched-async append and end up with a partially-written
        // file resurfacing on disk after the unlink.
        if let writer = self.wavWriter {
            try? writer.close()
            self.wavWriter = nil
        }
        try? FileManager.default.removeItem(at: Self.savedAudioURL)

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
            return TranscriptionResult(
                text: assembledText(),
                audioDuration: 0,
                lastResponseAge: nil,
                lastTranscriptAge: nil,
                maxSegmentGap: nil,
                savedAudioURL: nil
            )
        }
        isRunning = false

        teardownAudio()

        // Pad ~2s of silence into both the WAV and the outbound PCM buffer.
        // Doubao's streaming ASR needs trailing silence for its VAD to finalize
        // the last utterance — without this, releasing the hotkey right at the
        // end of a word loses the final 1-2 chars. 1s was insufficient in
        // real-world testing (user had to deliberately wait 1-2s of silence
        // before releasing or last char was eaten). 2s is the empirically-derived
        // value that matches Doubao's VAD threshold. The WAV also gets the
        // padding so a future retranscribe can recover the same way.
        let padSamples = DoubaoConstants.sampleRate * 2       // 2 seconds
        let padBytes = padSamples * MemoryLayout<Int16>.size
        self.pcmBuffer.append(Data(count: padBytes))
        self.totalPcmBytesOut += padBytes
        if let writer = self.wavWriter {
            let zeros = [Int16](repeating: 0, count: padSamples)
            zeros.withUnsafeBufferPointer { buf in
                writer.append(int16Samples: buf.baseAddress!, count: buf.count)
            }
        }

        if let writer = self.wavWriter {
            // close() blocks until all queued writes have flushed — this is what
            // makes it safe for the retranscribe path to read the file immediately
            // after stop() returns.
            try? writer.close()
            self.wavWriter = nil
        }

        // Drain ALL pending frames (including the 2s silence padding we just
        // added = 100 full frames at 320 samples/frame). flushPendingFrames is
        // load-bearing here — flushAndSendLastFrame alone would only handle the
        // very last partial frame.
        do {
            try await flushPendingFrames()
            try await flushAndSendLastFrame()
            try await sendFinishSession()
        } catch {
            doushaLog("[DoubaoASR] stop send error: \(error.localizedDescription)")
        }

        // Wait for SessionFinished. Doubao streaming ASR has ~1.5-2s first-response
        // latency, and long fast recordings can have several seconds of backlog
        // to flush after the server sees FinishSession. The official Doubao IME
        // client sets SAMICoreAsrContextCreateParameter.finish_wait_timeout = 10000,
        // so we mirror that — 4s was empirically too short for ~30s+ recordings
        // where the server backlog took longer to drain than the wait allowed.
        let waitStart = Date()
        let outcomeStr: String
        if let channel = finishedChannel {
            switch await waitWithTimeout(channel: channel, timeout: 10.0) {
            case .signaled: outcomeStr = "signaled"
            case .timeout: outcomeStr = "timedOut"
            case .cancelled: outcomeStr = "cancelled"
            case .failed: outcomeStr = "failed"
            }
        } else {
            outcomeStr = "no-channel"
        }
        doushaLog("[DoubaoASR] post-Finish wait \(Int(Date().timeIntervalSince(waitStart) * 1000))ms result=\(outcomeStr)")

        // Close the WebSocket after every session — see class doc.
        await closeWebSocket()

        let final = assembledText()
        doushaLog("[DoubaoASR] stop() final='\(final)' segments=\(committedSegments.count)")

        let audioDuration: TimeInterval = audioStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let lastResponseAge: TimeInterval? = lastResponseAt.map { Date().timeIntervalSince($0) }
        let lastTranscriptAge: TimeInterval? = lastTranscriptAt.map { Date().timeIntervalSince($0) }
        let savedURL: URL? = FileManager.default.fileExists(atPath: Self.savedAudioURL.path) ? Self.savedAudioURL : nil

        let maxSegmentGap: TimeInterval? = {
            // Only meaningful with 2+ commits — the lead gap from audioStartedAt
            // to the first commit is NOT a reliable signal (a user who talks
            // continuously without pausing has a "lead gap" equal to the entire
            // recording duration, but nothing was dropped). What IS a real signal
            // is silence between two committed segments: Doubao normally commits
            // every few seconds when VAD finalizes, so a >10s gap between two
            // commits means something happened mid-recording.
            guard segmentCommittedAt.count >= 2 else { return nil }
            var maxGap: TimeInterval = 0
            for i in 1..<segmentCommittedAt.count {
                let gap = segmentCommittedAt[i].timeIntervalSince(segmentCommittedAt[i-1])
                if gap > maxGap { maxGap = gap }
            }
            return maxGap
        }()

        return TranscriptionResult(
            text: final,
            audioDuration: audioDuration,
            lastResponseAge: lastResponseAge,
            lastTranscriptAge: lastTranscriptAge,
            maxSegmentGap: maxSegmentGap,
            savedAudioURL: savedURL
        )
    }

    private func teardownAudio() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
    }

    private func closeWebSocket() async {
        stopPingLoop()
        guard let ws = ws else {
            session?.invalidateAndCancel()
            session = nil
            taskStarted = false
            return
        }
        // Drop our reference first so the receive loop's success branch stops
        // rescheduling itself if a stray message arrives during the close handshake.
        self.ws = nil

        let channel = OneShotChannel<Void>()
        wsClosedChannel = channel

        // Send a WS Close frame (1000 Normal Closure). The server replies with its
        // own Close frame, which surfaces as a .failure on the receive loop and
        // signals wsClosedChannel.
        ws.cancel(with: .normalClosure, reason: nil)

        if case .timeout = await waitWithTimeout(channel: channel, timeout: 1.0) {
            doushaLog("[DoubaoASR] WS close handshake timed out — tearing down anyway")
        }
        wsClosedChannel = nil

        session?.invalidateAndCancel()
        session = nil
        taskStarted = false
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
        startReceiveLoop()
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
        ws.sendPing { error in
            if let error = error {
                doushaLog("[DoubaoASR] ws ping failed: \(error.localizedDescription)")
            }
        }
    }

    private func sendInitialMessages(deviceId: String) async throws {
        // StartTask: only on first session of this WebSocket (Doubao binds task to
        // connection; second StartTask would error "task already started").
        if !taskStarted {
            try await sendData(AsrMessageBuilder.startTask(requestId: requestId, token: token))
            let resp = try await waitForResponse(timeout: 5.0) {
                $0.messageType == "TaskStarted" || $0.messageType == "TaskFailed" || $0.messageType == "SessionFailed"
            }
            doushaLog("[DoubaoASR] StartTask resp messageType=\(resp.messageType) code=\(resp.statusCode) msg=\(resp.statusMessage)")
            if resp.messageType != "TaskStarted" {
                throw NSError(domain: "DoubaoASR", code: Int(resp.statusCode),
                              userInfo: [NSLocalizedDescriptionKey: "StartTask: \(resp.statusMessage.isEmpty ? "failed" : resp.statusMessage) (\(resp.statusCode))"])
            }
            taskStarted = true
        } else {
            doushaLog("[DoubaoASR] reusing task on existing WebSocket — skipping StartTask")
        }

        let configJSON = sessionConfigJSON(deviceId: deviceId)
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

        let outcome = await waitWithTimeout(channel: channel, timeout: timeout)
        pendingResponseFilter = nil
        pendingResponseChannel = nil

        switch outcome {
        case .signaled(let r): return r
        case .timeout: throw URLError(.timedOut)
        case .cancelled, .failed: throw URLError(.cannotParseResponse)
        }
    }

    private func sessionConfigJSON(deviceId: String) -> String {
        // `end_smooth_window_ms` and `use_twopass_retry` mirror the official
        // Doubao IME client's StartSession config. Without `end_smooth_window_ms`
        // the server falls back to a default VAD finalization window that has
        // been observed to truncate the tail of long utterances.
        let payload: [String: Any] = [
            "audio_info": [
                "channel": DoubaoConstants.channels,
                "format": "speech_opus",
                "sample_rate": DoubaoConstants.sampleRate
            ],
            "enable_punctuation": true,
            "enable_speech_rejection": false,
            "extra": [
                "app_name": "com.android.chrome",
                "cell_compress_rate": 8,
                "did": deviceId,
                "enable_asr_threepass": true,
                "enable_asr_twopass": true,
                "end_smooth_window_ms": 800,
                "input_mode": "tool",
                "use_twopass_retry": true
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func sendFinishSession() async throws {
        try await sendData(AsrMessageBuilder.finishSession(requestId: requestId, token: token))
    }

    private func sendData(_ data: Data) async throws {
        guard let ws = ws else { throw URLError(.networkConnectionLost) }
        try await ws.send(.data(data))
    }

    private func startReceiveLoop() {
        guard let ws = ws else { return }
        ws.receive { [weak self] result in
            // Bridge URLSession's delegate-queue callback into the actor.
            Task { await self?.handleReceiveResult(result) }
        }
    }

    private func handleReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, Error>) async {
        switch result {
        case .success(let msg):
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
                startReceiveLoop()
            }
        case .failure(let err):
            doushaLog("[DoubaoASR] receive failed: \(err.localizedDescription)")
            // Wake any closeWebSocket() awaiting the close handshake.
            wsClosedChannel?.finish(())
            if isRunning {
                deliverError(err)
            }
            // Connection is dead — drop references so next start() reopens.
            stopPingLoop()
            ws = nil
            session?.invalidateAndCancel()
            session = nil
            taskStarted = false
            pendingResponseFilter = nil
            pendingResponseChannel?.finish(throwing: CancellationError())
            pendingResponseChannel = nil
            signalFinished()
        }
    }

    private func handleResponseData(_ data: Data) {
        self.lastResponseAt = Date()
        guard let resp = try? AsrResponse.decode(data) else {
            doushaLog("[DoubaoASR] recv: decode failed (\(data.count) bytes)")
            return
        }
        doushaLog("[DoubaoASR] recv requestId=\(resp.requestId) messageType=\(resp.messageType) code=\(resp.statusCode) jsonLen=\(resp.resultJson.count)")

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

        // Parse result_json (per asr.py:589-684)
        guard !resp.resultJson.isEmpty,
              let rj = try? JSONSerialization.jsonObject(with: Data(resp.resultJson.utf8)) as? [String: Any] else {
            return
        }
        guard let results = rj["results"] as? [[String: Any]], !results.isEmpty else {
            return  // heartbeat
        }

        var text = ""
        var isInterim = true
        var vadFinished = false
        var nonstreamResult = false
        for r in results {
            if let t = r["text"] as? String, !t.isEmpty { text = t }
            if let i = r["is_interim"] as? Bool, i == false { isInterim = false }
            if let v = r["is_vad_finished"] as? Bool, v { vadFinished = true }
            if let extra = r["extra"] as? [String: Any], let n = extra["nonstream_result"] as? Bool, n {
                nonstreamResult = true
            }
        }

        if !text.isEmpty {
            self.lastTranscriptAt = Date()
            // Doubao chunks long audio into VAD-bounded utterances. Each utterance has its
            // own cumulative `text` field that does NOT include prior utterances. So when
            // is_vad_finished=true && !is_interim, we commit `text` as a finalized
            // segment; the next utterance's interims start from empty again. The HUD and
            // final paste join all committed segments + the in-progress interim.
            if (!isInterim && vadFinished) || nonstreamResult {
                committedSegments.append(text)
                segmentCommittedAt.append(Date())
                currentInterim = ""
                doushaLog("[DoubaoASR] segment final='\(text)' totalSegments=\(committedSegments.count)")
            } else {
                currentInterim = text
            }
            let display = committedSegments.joined() + currentInterim
            let cb = onPartial
            DispatchQueue.main.async { cb?(display) }
        }
    }

    private func assembledText() -> String {
        committedSegments.joined() + currentInterim
    }

    private func signalFinished() {
        finishedChannel?.finish(())
    }

    // MARK: - Mic capture

    private func startMicTap() throws {
        let inputNode = audioEngine.inputNode
        let inFormat = inputNode.outputFormat(forBus: 0)

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(DoubaoConstants.sampleRate),
            channels: AVAudioChannelCount(DoubaoConstants.channels),
            interleaved: true
        ) else {
            throw OpusEncoder.OpusError.formatBuildFailed
        }
        self.pcmTargetFormat = target

        guard let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw OpusEncoder.OpusError.converterInitFailed
        }
        self.pcmConverter = converter

        // Snapshot for the audio-thread closure so it doesn't reach into actor state.
        let audioLevelCallback = self.onAudioLevel
        let capturedConverter = UncheckedSendable(converter)
        let capturedTarget = UncheckedSendable(target)
        let capturedWavWriter = self.wavWriter   // may be nil — that's fine

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            // Audio thread — must not block.
            let level = AudioLevel.computeRMS(buffer)
            DispatchQueue.main.async { audioLevelCallback?(level) }

            let converter = capturedConverter.value
            let target = capturedTarget.value

            let ratio = target.sampleRate / buffer.format.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return }

            var fed = false
            var convError: NSError?
            _ = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if let e = convError {
                doushaLog("[DoubaoASR] mic convert error: \(e)")
                return
            }
            let n = Int(outBuf.frameLength)
            guard n > 0, let src = outBuf.int16ChannelData?[0] else { return }

            if let writer = capturedWavWriter {
                writer.append(int16Samples: src, count: n)
            }

            let byteCount = n * MemoryLayout<Int16>.size
            let chunk = Data(bytes: src, count: byteCount)

            Task { await self?.appendAndDrainPCM(chunk) }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func appendAndDrainPCM(_ data: Data) async {
        guard isRunning else { return }
        totalPcmBytesOut += data.count
        pcmBuffer.append(data)
        try? await flushPendingFrames()
    }

    /// Sends as many complete 20ms frames as the buffer holds. No-op until
    /// `canSendAudio` is true (i.e., until StartSession has succeeded).
    private func flushPendingFrames() async throws {
        guard canSendAudio else { return }
        let frameSize = DoubaoConstants.bytesPerFrame
        while pcmBuffer.count >= frameSize {
            let frame = pcmBuffer.prefix(frameSize)
            pcmBuffer.removeFirst(frameSize)
            do {
                let state: FrameState = didSendFirstFrame ? .middle : .first
                try await encodeAndSend(Data(frame), state: state)
                if !didSendFirstFrame {
                    doushaLog("[DoubaoASR] sent FIRST frame")
                }
                didSendFirstFrame = true
                framesSentCount += 1
            } catch {
                doushaLog("[DoubaoASR] encodeAndSend error: \(error.localizedDescription)")
                deliverError(error)
                return
            }
        }
    }

    private func flushAndSendLastFrame() async throws {
        doushaLog("[DoubaoASR] flushAndSendLastFrame framesSent=\(framesSentCount) pcmBufferRemaining=\(pcmBuffer.count) didSendFirst=\(didSendFirstFrame) totalPcmBytesOut=\(totalPcmBytesOut)")
        let frameSize = DoubaoConstants.bytesPerFrame
        if pcmBuffer.isEmpty {
            // Still need a LAST marker if any frames were sent.
            if didSendFirstFrame {
                let silent = Data(count: frameSize)
                try await encodeAndSend(silent, state: .last)
                doushaLog("[DoubaoASR] sent LAST silent")
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
        doushaLog("[DoubaoASR] sent LAST frame")
    }

    private func encodeAndSend(_ pcmFrame: Data, state: FrameState) async throws {
        guard let encoder = opusEncoder else { return }
        let opus = try encoder.encode(pcmFrame)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let msg = AsrMessageBuilder.taskRequest(
            audio: opus,
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

    // MARK: - Retranscribe

    /// Open a fresh session and stream the given WAV file's audio through Doubao,
    /// returning the final transcript. Does NOT touch the mic or HUD. The caller
    /// (DoubaoBackend) is responsible for showing whatever UI it wants.
    ///
    /// On any error, returns whatever partial text was assembled (possibly empty).
    public func retranscribe(wavURL: URL) async -> String {
        doushaLog("[DoubaoASR] retranscribe(\(wavURL.lastPathComponent)) starting")

        // Don't let a retranscribe stomp on a live recording session.
        guard !isRunning else {
            doushaLog("[DoubaoASR] retranscribe rejected — session already running")
            return ""
        }

        // Quarantine the live-session callbacks so a server error during retranscribe
        // doesn't bleed into AppDelegate's recording-error handler. Restored on exit.
        let savedOnPartial = self.onPartial
        let savedOnAudioLevel = self.onAudioLevel
        let savedOnError = self.onError
        defer {
            self.onPartial = savedOnPartial
            self.onAudioLevel = savedOnAudioLevel
            self.onError = savedOnError
        }
        self.onPartial = { _ in }
        self.onAudioLevel = { _ in }
        self.onError = { _ in }

        // Reset session state (mirrors what start() does, minus the mic tap).
        self.committedSegments = []
        self.currentInterim = ""
        self.pcmBuffer = Data()
        self.didSendFirstFrame = false
        self.canSendAudio = false
        self.didReceiveFinal = false
        self.framesSentCount = 0
        self.totalPcmBytesOut = 0
        self.requestId = UUID().uuidString.lowercased()
        self.finishedChannel = OneShotChannel<Void>()
        self.lastResponseAt = nil
        self.lastTranscriptAt = nil
        self.audioStartedAt = Date()
        self.isRunning = true
        defer { self.isRunning = false }

        do {
            let creds = try await DoubaoCredentialStore.shared.ensureCredentials()
            self.token = creds.token
            self.deviceId = creds.deviceId

            self.opusEncoder = try OpusEncoder()

            // Always force a fresh WebSocket + task for retranscribe — Doubao binds
            // tasks to connections, and reusing a half-closed WS would silently skip
            // StartTask via sendInitialMessages and run on stale task state.
            await closeWebSocket()
            self.taskStarted = false
            try openWebSocket()
            try await sendInitialMessages(deviceId: self.deviceId)
            self.canSendAudio = true

            try await streamWavFile(at: wavURL)

            try await sendFinishSession()

            // Match the main session's 10s wait — retranscribe burst-sends the
            // whole WAV in one shot, so the server's post-finish processing
            // backlog can be substantial. 5s was observed to cut the server off
            // mid-decode on long recordings (jsonLen still growing when we hung up).
            if let channel = finishedChannel {
                _ = await waitWithTimeout(channel: channel, timeout: 10.0)
            }
        } catch {
            doushaLog("[DoubaoASR] retranscribe error: \(error.localizedDescription)")
        }

        await closeWebSocket()

        let final = assembledText()
        doushaLog("[DoubaoASR] retranscribe done text.len=\(final.count)")
        return final
    }

    /// Read a WAV file and push its int16 PCM through the existing send pipeline
    /// in 20ms frames at ~realtime pace. We pace because Doubao's streaming ASR is
    /// designed around mic-rate input, and feeding 30s of audio in a single burst
    /// risks: (a) the server rejecting/throttling the connection, (b) the server's
    /// VAD/partial-result loop collapsing into one giant utterance that returns
    /// less granular text. Realtime pacing makes the replay indistinguishable from
    /// a live mic session from the server's perspective.
    private func streamWavFile(at url: URL) async throws {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "DoubaoASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "WAV buffer alloc failed"])
        }
        try file.read(into: buf)

        // Convert to our send format (int16 16kHz mono interleaved) if needed.
        let target = pcmTargetFormat ?? AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(DoubaoConstants.sampleRate),
            channels: AVAudioChannelCount(DoubaoConstants.channels),
            interleaved: true
        )!
        let outBuf: AVAudioPCMBuffer
        if buf.format == target {
            outBuf = buf
        } else {
            guard let converter = AVAudioConverter(from: buf.format, to: target),
                  let conv = AVAudioPCMBuffer(pcmFormat: target,
                                              frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate + 1024)) else {
                throw NSError(domain: "DoubaoASR", code: -2, userInfo: [NSLocalizedDescriptionKey: "WAV converter init failed"])
            }
            var error: NSError?
            var fed = false
            converter.convert(to: conv, error: &error) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            if let e = error { throw e }
            outBuf = conv
        }

        // Burst the entire WAV through the existing send pipeline. We previously
        // paced each 20ms frame with a 20ms sleep "to match mic rate" out of
        // caution about Doubao throttling, but the resulting ~realtime latency
        // (30s replay for a 30s recording) was the dominant UX problem when the
        // heuristic-retry kicks in. Burst-sending should be fine — Doubao's WS
        // protocol doesn't advertise a rate limit, and any backpressure would
        // surface as a WS error we can react to. Re-add pacing if that happens.
        guard let i16 = outBuf.int16ChannelData?[0] else { return }
        let totalSamples = Int(outBuf.frameLength)
        let totalBytes = totalSamples * MemoryLayout<Int16>.size
        let allData = Data(bytes: UnsafeRawPointer(i16), count: totalBytes)
        self.pcmBuffer.append(allData)
        self.totalPcmBytesOut += totalBytes
        try await flushPendingFrames()
        try await flushAndSendLastFrame()
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
