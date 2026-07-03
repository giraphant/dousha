import Foundation
@preconcurrency import AVFoundation
import ASRSupport
import ConcurrencySupport

/// The single microphone capture point for a recording (spec §1). Owns the one
/// `AVAudioEngine` + mic tap and fans the raw audio out to every active engine,
/// doing the shared work exactly once per buffer:
///
///   • `AudioLevel.computeRMS` → `onLevel` (drives the HUD — one level)
///   • the native `AVAudioPCMBuffer` → **buffer sinks** (Apple Speech, which
///     feeds `SFSpeech` native-format buffers directly)
///   • int16 16 kHz mono PCM, converted **once** → one shared WAV **and** the
///     **PCM sinks** (Doubao, Soniox)
///
/// This replaces the per-engine `AVAudioEngine`/tap/`WavFileWriter`/RMS that
/// `DoubaoASR`/`SonioxASR`/`AppleSpeechBackend` each used to own — so N engines
/// now share ONE tap, one conversion, one WAV.
///
/// Lifecycle (driven by `MultiEngineBackend`): `startCapture` after every engine
/// has reset its session state (so an early buffer isn't dropped), then
/// `stopCapture` (drains the in-flight tail before engines flush) or
/// `cancelCapture`. The audio-thread tap closure captures only local copies and
/// never hops back into this actor, so it stays real-time safe.
actor AudioTapHub {
    /// Consumes int16 16 kHz mono PCM, pushed as `Data` chunks (Doubao, Soniox).
    typealias PCMSink = @Sendable (Data) -> Void
    /// Consumes the native-format mic buffer (Apple feeds `SFSpeech` directly).
    typealias BufferSink = @Sendable (AVAudioPCMBuffer) -> Void

    private static let captureStartAttempts = 3
    private static let captureRetryDelayNanoseconds: UInt64 = 100_000_000
    private static let configurationDebounceNanoseconds: UInt64 = 100_000_000

    private let audioEngine = AVAudioEngine()
    private let pcmSinks: [PCMSink]
    private let bufferSinks: [BufferSink]
    private let wantsWAV: Bool
    private var wavWriter: WavFileWriter?
    private var capturing = false
    private var levelSink: (@Sendable (Float) -> Void)?
    private var configObserver: NSObjectProtocol?
    private var restartPending = false
    private var captureGeneration = 0

    /// - Parameters:
    ///   - pcmSinks: int16-PCM consumers (Doubao/Soniox `ingest`).
    ///   - bufferSinks: native-buffer consumers (Apple `ingest`).
    ///   - wantsWAV: write the shared WAV (true whenever a PCM engine is active;
    ///     the WAV is the Soniox-async upload payload).
    init(pcmSinks: [PCMSink], bufferSinks: [BufferSink], wantsWAV: Bool) {
        self.pcmSinks = pcmSinks
        self.bufferSinks = bufferSinks
        self.wantsWAV = wantsWAV
    }

    /// Opens the shared WAV, installs the mic tap and starts the engine. Must be
    /// called AFTER every engine has reset its session state (PCM arriving before
    /// `isRunning` flips would be dropped → lost opening words).
    ///
    /// Startup is retried because macOS can briefly reconfigure the default input
    /// device while another audio app / Bluetooth profile is already active. Each
    /// attempt re-reads the live input format and rebuilds the converter.
    func startCapture(onLevel: @escaping @Sendable (Float) -> Void) async throws {
        guard !capturing else { return }

        captureGeneration += 1
        levelSink = onLevel
        restartPending = false

        if wantsWAV {
            try? FileManager.default.removeItem(at: AudioCapturePaths.sharedWAV)
            do {
                wavWriter = try WavFileWriter(url: AudioCapturePaths.sharedWAV,
                                              sampleRate: 16_000, channels: 1)
                doushaLog("[AudioTapHub] shared WAV opened at \(AudioCapturePaths.sharedWAV.path)")
            } catch {
                doushaLog("[AudioTapHub] WAV open failed: \(error.localizedDescription) — continuing without it")
                wavWriter = nil
            }
        }

        registerConfigurationObserver()

        do {
            let inputFormat = try await startWithRetry(onLevel: onLevel, label: "capture start")
            capturing = true
            doushaLog("[AudioTapHub] capture started inputFormat=\(inputFormat) pcmSinks=\(pcmSinks.count) bufferSinks=\(bufferSinks.count) wav=\(wavWriter != nil)")
        } catch {
            unregisterConfigurationObserver()
            levelSink = nil
            restartPending = false
            removeTapStopAndReset()
            closeSharedWAV(deleteFile: true)
            throw error
        }
    }

    /// Removes the tap, then holds a short drain window so the last buffers the
    /// tap dispatched (the tail the user spoke microseconds before releasing)
    /// land on the engine actors' `pcmBuffer` before the engines flush + finish.
    /// Mirrors the old per-actor `stopDrainWindow`; the WAV is closed afterward
    /// so it's readable immediately (Soniox async upload).
    func stopCapture() async {
        guard capturing else { return }
        capturing = false
        captureGeneration += 1
        restartPending = false
        levelSink = nil
        unregisterConfigurationObserver()
        removeTapStopAndReset()
        // Wall-clock drain: lets the audio thread's last dispatched ingest Tasks
        // get created + processed on each engine actor. The engines additionally
        // yield at the top of their finish() to flush their own queue.
        for _ in 0..<4 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms drain window for the tail buffers
        closeSharedWAV(deleteFile: false)
        doushaLog("[AudioTapHub] capture stopped + drained")
    }

    /// Aborts capture and discards the WAV. No drain — the recording is being
    /// thrown away.
    func cancelCapture() {
        captureGeneration += 1
        capturing = false
        restartPending = false
        levelSink = nil
        unregisterConfigurationObserver()
        removeTapStopAndReset()
        closeSharedWAV(deleteFile: true)
        doushaLog("[AudioTapHub] capture cancelled")
    }

    private func startWithRetry(onLevel: @escaping @Sendable (Float) -> Void,
                                label: String,
                                generation: Int? = nil) async throws -> String {
        var lastError: Error?
        for attempt in 1...Self.captureStartAttempts {
            try ensureCurrent(generation: generation)
            removeTapStopAndReset()
            do {
                let inputFormat = try installTapAndStart(onLevel: onLevel)
                if attempt > 1 {
                    doushaLog("[AudioTapHub] \(label) recovered on attempt \(attempt)")
                }
                return inputFormat
            } catch {
                lastError = error
                doushaLog("[AudioTapHub] \(label) attempt \(attempt) failed: \(error.localizedDescription)")
                removeTapStopAndReset()
                guard attempt < Self.captureStartAttempts else { break }
                try ensureCurrent(generation: generation)
                try? await Task.sleep(nanoseconds: Self.captureRetryDelayNanoseconds)
            }
        }
        try ensureCurrent(generation: generation)
        throw lastError ?? NSError(domain: "AudioTapHub", code: -2,
                                   userInfo: [NSLocalizedDescriptionKey: "Failed to start mic capture"])
    }

    private func installTapAndStart(onLevel: @escaping @Sendable (Float) -> Void) throws -> String {
        let inputNode = audioEngine.inputNode
        let inFormat = inputNode.outputFormat(forBus: 0)
        let inputDescription = describe(format: inFormat)

        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "AudioTapHub", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid mic input format: \(inputDescription)"])
        }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16_000, channels: 1,
                                         interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw NSError(domain: "AudioTapHub", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to build mic audio converter"])
        }

        // Snapshots for the audio-thread closure — it must not touch actor state.
        let pcmSinks = self.pcmSinks
        let bufferSinks = self.bufferSinks
        let capturedConverter = UncheckedSendable(converter)
        let capturedTarget = UncheckedSendable(target)
        let capturedWAV = self.wavWriter
        // Only do the int16 conversion if someone actually consumes it (a PCM
        // engine or the WAV). Apple-only recordings skip it entirely.
        let needPCM = !pcmSinks.isEmpty || capturedWAV != nil

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in
            // Audio thread — fast, no actor hop, no blocking.
            let level = AudioLevel.computeRMS(buffer)
            DispatchQueue.main.async { onLevel(level) }

            // Apple wants the untouched native buffer.
            for sink in bufferSinks { sink(buffer) }

            guard needPCM else { return }

            let converter = capturedConverter.value
            let target = capturedTarget.value
            let ratio = target.sampleRate / buffer.format.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { return }

            // Synchronous: the converter input block runs inline within
            // convert(to:error:), never concurrently — so this var is not
            // actually shared across threads despite the @Sendable block type.
            nonisolated(unsafe) var fed = false
            var convError: NSError?
            _ = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if let e = convError {
                doushaLog("[AudioTapHub] mic convert error: \(e)")
                return
            }
            let n = Int(outBuf.frameLength)
            guard n > 0, let src = outBuf.int16ChannelData?[0] else { return }

            if let wav = capturedWAV { wav.append(int16Samples: src, count: n) }

            if !pcmSinks.isEmpty {
                let chunk = Data(bytes: src, count: n * MemoryLayout<Int16>.size)
                for sink in pcmSinks { sink(chunk) }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        return inputDescription
    }

    private func registerConfigurationObserver() {
        unregisterConfigurationObserver()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.handleConfigurationChange() }
        }
    }

    private func unregisterConfigurationObserver() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
    }

    private func handleConfigurationChange() async {
        guard capturing else { return }
        guard !restartPending else { return }
        restartPending = true
        let generation = captureGeneration
        doushaLog("[AudioTapHub] engine configuration changed — scheduling capture restart")

        try? await Task.sleep(nanoseconds: Self.configurationDebounceNanoseconds)

        guard capturing, generation == captureGeneration, let onLevel = levelSink else {
            if generation == captureGeneration { restartPending = false }
            return
        }

        do {
            let inputFormat = try await startWithRetry(onLevel: onLevel,
                                                       label: "capture restart",
                                                       generation: generation)
            if capturing, generation == captureGeneration {
                doushaLog("[AudioTapHub] capture restart succeeded inputFormat=\(inputFormat)")
            }
        } catch is CancellationError {
            // Stop/cancel won the race while the debounced restart was pending.
        } catch {
            if capturing, generation == captureGeneration {
                doushaLog("[AudioTapHub] capture restart failed: \(error.localizedDescription)")
            }
        }

        if generation == captureGeneration { restartPending = false }
    }

    private func ensureCurrent(generation: Int?) throws {
        guard let generation else { return }
        guard capturing, generation == captureGeneration else { throw CancellationError() }
    }

    private func removeTapStopAndReset() {
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.reset()
    }

    private func closeSharedWAV(deleteFile: Bool) {
        if let wav = wavWriter {
            try? wav.close()
            wavWriter = nil
        }
        if deleteFile {
            try? FileManager.default.removeItem(at: AudioCapturePaths.sharedWAV)
        }
    }

    private func describe(format: AVAudioFormat) -> String {
        "sampleRate=\(Int(format.sampleRate)) channels=\(format.channelCount) commonFormat=\(format.commonFormat) interleaved=\(format.isInterleaved)"
    }
}
