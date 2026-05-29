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

    private let audioEngine = AVAudioEngine()
    private var pcmConverter: AVAudioConverter?
    private var pcmTargetFormat: AVAudioFormat?

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
    /// the URLSession.
    private var wsClosedChannel: OneShotChannel<Void>?

    /// Periodic keepalive control frame. Started only AFTER the config message
    /// is sent (the first frame must be config), and cancelled in
    /// closeWebSocket() and on receive-loop failure. Without it the server tears
    /// down idle connections, which on a long recording with mid-sentence
    /// pauses cuts the recording off early.
    private var keepaliveTask: Task<Void, Never>?

    // Callbacks (assigned in start)
    private var onPartial: (@Sendable (String) -> Void)?
    private var onAudioLevel: (@Sendable (Float) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?

    private var totalPcmBytesOut: Int = 0

    // WAV side-recording for fallback retranscription. Held so the audio-thread
    // tap closure (non-isolated) can call .append() directly without hopping
    // into the actor; the actor's reference is just for close().
    private var wavWriter: WavFileWriter?
    private var audioStartedAt: Date?
    private var lastResponseAt: Date?
    private var lastTranscriptAt: Date?

    /// Per-engine WAV path so Soniox and Doubao don't clobber each other's
    /// last-recording file.
    public static var savedAudioURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dousha", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last_recording_soniox.wav")
    }

    /// Creates an idle recognizer. No mic, network, or key validation happens
    /// until `start()`.
    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    // MARK: - Lifecycle

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
        self.parser = SonioxResponseParser()
        self.pcmBuffer = Data()
        self.canSendAudio = false
        self.totalPcmBytesOut = 0
        self.requestId = UUID().uuidString.lowercased()
        self.finishedChannel = OneShotChannel<Void>()
        self.audioStartedAt = nil
        self.lastResponseAt = nil
        self.lastTranscriptAt = nil
        self.wavWriter = nil

        doushaLog("[SonioxASR] traceId=\(requestId) start")

        guard !apiKey.isEmpty else {
            let err = NSError(domain: "SonioxASR", code: 401,
                              userInfo: [NSLocalizedDescriptionKey: "Soniox API key is missing. Add it in Settings."])
            deliverError(err)
            isRunning = false
            signalFinished()
            return
        }

        do {
            // Open the rolling WAV before the mic tap so startMicTap can snapshot
            // the writer reference into the tap closure.
            do {
                try? FileManager.default.removeItem(at: Self.savedAudioURL)
                self.wavWriter = try WavFileWriter(
                    url: Self.savedAudioURL,
                    sampleRate: SonioxConfig.sampleRate,
                    channels: SonioxConfig.channels
                )
                self.audioStartedAt = Date()
                doushaLog("[SonioxASR] WAV side-recording opened at \(Self.savedAudioURL.path)")
            } catch {
                doushaLog("[SonioxASR] WAV writer failed to open: \(error.localizedDescription) — continuing without side recording")
                self.wavWriter = nil
            }

            // Start mic FIRST so audio buffers while the WS sets up.
            try startMicTap()
            doushaLog("[SonioxASR] mic tap started (pre-WS)")

            try openWebSocket()
            try await sendConfigMessage()
            doushaLog("[SonioxASR] traceId=\(requestId) config sent pcmBufferBytes=\(pcmBuffer.count)")

            // Keepalive only after the config frame is on the wire (the first
            // frame must be config). Flip the audio gate for the same reason.
            startKeepalive()
            self.canSendAudio = true
            try await flushPendingFrames()
        } catch {
            doushaLog("[SonioxASR] start() failed: \(error.localizedDescription)")
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
        self.onAudioLevel = nil
        self.onError = nil

        teardownAudio()

        if let writer = self.wavWriter {
            try? writer.close()
            self.wavWriter = nil
        }
        try? FileManager.default.removeItem(at: Self.savedAudioURL)

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
        isRunning = false

        teardownAudio()

        if let writer = self.wavWriter {
            // close() blocks until queued writes flush — makes it safe for the
            // retranscribe path to read the file right after stop() returns.
            try? writer.close()
            self.wavWriter = nil
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

        await closeWebSocket()

        let result = makeResult()
        doushaLog("[SonioxASR] traceId=\(requestId) stop final text.len=\(result.text.count)")
        return result
    }

    private func makeResult() -> TranscriptionResult {
        let audioDuration: TimeInterval = audioStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let lastResponseAge: TimeInterval? = lastResponseAt.map { Date().timeIntervalSince($0) }
        let lastTranscriptAge: TimeInterval? = lastTranscriptAt.map { Date().timeIntervalSince($0) }
        let savedURL: URL? = FileManager.default.fileExists(atPath: Self.savedAudioURL.path) ? Self.savedAudioURL : nil
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

    private func teardownAudio() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
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
        // Invalidate the old socket's receive callbacks NOW (before awaiting the
        // close handshake) so a trailing message during the close/reopen gap
        // can't mutate freshly-reset session state (e.g. in retranscribe). The
        // failure callback still signals wsClosedChannel below — see
        // handleReceiveResult — so the handshake completes promptly.
        wsGeneration += 1

        let channel = OneShotChannel<Void>()
        wsClosedChannel = channel
        ws.cancel(with: .normalClosure, reason: nil)

        if case .timeout = await waitWithTimeout(channel: channel, timeout: 1.0) {
            doushaLog("[SonioxASR] WS close handshake timed out — tearing down anyway")
        }
        wsClosedChannel = nil

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
        let json = SonioxConfig.configMessageJSON(apiKey: apiKey)
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
            // block the full 1s timeout.
            wsClosedChannel?.finish(())
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
            let display = update.displayText
            let cb = onPartial
            DispatchQueue.main.async { cb?(display) }
        }

        if update.finished {
            doushaLog("[SonioxASR] traceId=\(requestId) finished")
            signalFinished()
        }
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
            sampleRate: Double(SonioxConfig.sampleRate),
            channels: AVAudioChannelCount(SonioxConfig.channels),
            interleaved: true
        ) else {
            throw NSError(domain: "SonioxASR", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to build target audio format"])
        }
        self.pcmTargetFormat = target

        guard let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw NSError(domain: "SonioxASR", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to init audio converter"])
        }
        self.pcmConverter = converter

        let audioLevelCallback = self.onAudioLevel
        let capturedConverter = UncheckedSendable(converter)
        let capturedTarget = UncheckedSendable(target)
        let capturedWavWriter = self.wavWriter

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
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
                doushaLog("[SonioxASR] mic convert error: \(e)")
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

    // MARK: - Retranscribe

    /// Open a fresh session and stream the given WAV file's audio through
    /// Soniox, returning the final transcript. Does NOT touch the mic or HUD.
    /// On any error, returns whatever partial text was assembled.
    public func retranscribe(wavURL: URL, parentTraceId: String? = nil) async -> String {
        guard !isRunning else {
            doushaLog("[SonioxASR] retranscribe rejected — session already running")
            return ""
        }
        guard !apiKey.isEmpty else {
            doushaLog("[SonioxASR] retranscribe rejected — missing API key")
            return ""
        }

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

        self.parser = SonioxResponseParser()
        self.pcmBuffer = Data()
        self.canSendAudio = false
        self.totalPcmBytesOut = 0
        self.requestId = UUID().uuidString.lowercased()
        let parentField = parentTraceId.map { " parent_traceId=\($0)" } ?? ""
        doushaLog("[SonioxASR] traceId=\(requestId)\(parentField) retranscribe \(wavURL.lastPathComponent) starting")
        self.finishedChannel = OneShotChannel<Void>()
        self.lastResponseAt = nil
        self.lastTranscriptAt = nil
        self.audioStartedAt = Date()
        self.isRunning = true
        defer { self.isRunning = false }

        do {
            await closeWebSocket()
            try openWebSocket()
            try await sendConfigMessage()
            self.canSendAudio = true

            try await streamWavFile(at: wavURL)
            try await sendEndOfAudio()

            if let channel = finishedChannel {
                _ = await waitWithTimeout(channel: channel, timeout: 10.0)
            }
        } catch {
            doushaLog("[SonioxASR] traceId=\(requestId)\(parentField) retranscribe error=\(error.localizedDescription)")
        }

        await closeWebSocket()
        let final = parser.displayText
        doushaLog("[SonioxASR] traceId=\(requestId)\(parentField) retranscribe done text.len=\(final.count)")
        return final
    }

    /// Read a WAV file, convert to int16 16kHz mono, and burst it through the
    /// send pipeline. Soniox accepts whole-file bursts (it's designed around
    /// streaming but doesn't penalize a fast feed for short clips).
    private func streamWavFile(at url: URL) async throws {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "SonioxASR", code: -1, userInfo: [NSLocalizedDescriptionKey: "WAV buffer alloc failed"])
        }
        try file.read(into: buf)

        let target = pcmTargetFormat ?? AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(SonioxConfig.sampleRate),
            channels: AVAudioChannelCount(SonioxConfig.channels),
            interleaved: true
        )!
        let outBuf: AVAudioPCMBuffer
        if buf.format == target {
            outBuf = buf
        } else {
            guard let converter = AVAudioConverter(from: buf.format, to: target),
                  let conv = AVAudioPCMBuffer(pcmFormat: target,
                                              frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate + 1024)) else {
                throw NSError(domain: "SonioxASR", code: -2, userInfo: [NSLocalizedDescriptionKey: "WAV converter init failed"])
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

        guard let i16 = outBuf.int16ChannelData?[0] else { return }
        let totalSamples = Int(outBuf.frameLength)
        let totalBytes = totalSamples * MemoryLayout<Int16>.size
        let allData = Data(bytes: UnsafeRawPointer(i16), count: totalBytes)
        self.pcmBuffer.append(allData)
        self.totalPcmBytesOut += totalBytes
        try await flushPendingFrames()
        try await flushLastPartialFrame()
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
