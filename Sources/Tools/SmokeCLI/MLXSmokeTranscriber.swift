import Foundation
import ASRSupport
import MLXASR

struct MLXSmokeOptions {
    let wavPath: String
    var model = MLXModelCatalog.defaultModel.repoID
    var language = "auto"
    var realtime = false
    var prewarm = false
    var finalPass = true
    var context = ""

    private struct UsageError: LocalizedError {
        let errorDescription: String?
    }

    init(arguments: [String]) throws {
        var path: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--model", "--language", "--context", "--final-pass":
                guard index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("--"), !arguments[index + 1].isEmpty else {
                    throw UsageError(errorDescription: "\(argument) requires a value")
                }
                index += 1
                switch argument {
                case "--model": model = arguments[index]
                case "--language": language = arguments[index]
                case "--context": context = arguments[index]
                default:
                    guard ["on", "off"].contains(arguments[index]) else {
                        throw UsageError(errorDescription: "--final-pass requires on or off")
                    }
                    finalPass = arguments[index] == "on"
                }
            case "--prewarm":
                prewarm = true
            case "--realtime":
                realtime = true
            default:
                guard !argument.hasPrefix("--"), path == nil else {
                    throw UsageError(errorDescription: "unexpected argument: \(argument)")
                }
                path = argument
            }
            index += 1
        }
        guard let path else { throw UsageError(errorDescription: "missing <file.wav>") }
        wavPath = (path as NSString).expandingTildeInPath
    }
}

/// All observations stay on main, matching the engine callback contract.
/// Async sleeps and a continuation keep DispatchQueue.main serviced throughout
/// model loading, audio feeding and stop; never block here with a semaphore.
@MainActor
final class MLXSmokeTranscriber {
    private var partialCount = 0
    private var firstPartialAt: TimeInterval?
    private var audioStartedAt: TimeInterval?
    private var failure: String?
    private var previewText = ""
    private var completion: CheckedContinuation<TranscriptionResult?, Never>?
    private var watchdog: Task<Void, Never>?

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func run(_ options: MLXSmokeOptions) async -> Bool {
        let pcm: Data
        do {
            pcm = try WavReader.readPCM(path: options.wavPath)
        } catch {
            print("wav: FAILED — \(error.localizedDescription)")
            return false
        }
        print("wav: \(pcm.count) bytes, \(String(format: "%.3f", Double(pcm.count) / 32_000))s @16kHz mono s16le")
        print("mlx: model=\(options.model) language=\(options.language) realtime=\(options.realtime) prewarm=\(options.prewarm) final_pass=\(options.finalPass ? "on" : "off")")

        let model = MLXModelDescriptor(repoID: options.model, displayName: options.model)
        let store = MLXModelStore.shared
        if options.prewarm {
            let started = now
            await store.preload(model)
            print("preload_ms: \(milliseconds(now - started)) (load + kernel prewarm)")
        }
        let engine = MLXStreamingASR(model: model, store: store, finalPass: options.finalPass)
        await engine.prepareSession(onPartial: { partial in
            MainActor.assumeIsolated {
                self.partialCount += 1
                self.previewText = partial.combined
                if self.firstPartialAt == nil { self.firstPartialAt = self.now }
            }
        }, onError: { error in
            MainActor.assumeIsolated {
                self.failure = error.localizedDescription
                print("mlx: ERROR — \(error.localizedDescription)")
            }
        }, language: options.language, context: options.context)
        let loadStarted = now
        engine.openStream()

        // A first download can take longer than stop's 30s setup allowance.
        // Observe the real store after openStream; do not preload a second model
        // or bypass the engine's process-wide lease. This samples readiness at
        // 20ms resolution and includes download time on a cold cache.
        var loadSeconds: TimeInterval?
        while now - loadStarted < 600, failure == nil {
            switch await store.state {
            case .ready(let repoID) where repoID == options.model:
                loadSeconds = now - loadStarted
            case .failed(let repoID, let message) where repoID == options.model:
                failure = message
            default:
                break
            }
            if loadSeconds != nil || failure != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let loadSeconds, failure == nil else {
            engine.cancel()
            print("mlx: FAILED — \(failure ?? "model load timed out after 600s")")
            printMetrics(load: nil, stop: nil, finalLength: 0)
            return false
        }
        print("model_load_ms: \(milliseconds(loadSeconds)) (open→ready, includes any download)")

        // 100ms = 1,600 int16 samples. ingest is a lock-only append; the engine's
        // background feeder drains independently, with no backpressure API.
        let chunkBytes = 3_200
        let audioStarted = now
        audioStartedAt = audioStarted
        var offset = 0
        while offset < pcm.count, failure == nil {
            let end = min(offset + chunkBytes, pcm.count)
            engine.ingest(pcm.subdata(in: offset..<end))
            offset = end
            let delay = options.realtime ? max(0, audioStarted + Double(offset) / 32_000 - now) : 0.01
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        }
        print("audio: fed \(offset) bytes in \(milliseconds(now - audioStarted))ms")

        let stopStarted = now
        let result = await finish(engine, audioSeconds: Double(pcm.count) / 32_000)
        let stopSeconds = now - stopStarted
        printMetrics(load: loadSeconds, stop: stopSeconds, finalLength: result?.text.count ?? 0)
        if let metrics = await engine.finalPassMetrics {
            print("final_pass: batch_ms=\(String(format: "%.1f", metrics.batchMilliseconds)) final_source=\(metrics.source) deadline_seconds=\(metrics.deadlineSeconds)")
        }
        print("streaming_preview_text: \(previewText)")
        if let result {
            print("trace_id: \(result.traceId ?? "none")")
            print("final_text: \(result.text)")
        }
        return failure == nil && result?.text.isEmpty == false
    }

    private func finish(_ engine: MLXStreamingASR, audioSeconds: Double) async -> TranscriptionResult? {
        await withCheckedContinuation { continuation in
            completion = continuation
            // Cover 30s setup + 10s stream + 3s cleanup + the scaled batch
            // deadline, with margin, so long WAVs don't hit the watchdog early.
            let timeout = max(80, 48 + MLXFinalPassDeadline().seconds(forAudioSeconds: audioSeconds))
            watchdog = Task {
                do { try await Task.sleep(for: .seconds(timeout)) }
                catch { return }
                failure = "stop completion timed out after \(timeout)s"
                print("mlx: ERROR — \(failure!)")
                engine.cancel()
                resolve(nil)
            }
            engine.stop { result in
                MainActor.assumeIsolated { self.resolve(result) }
            }
        }
    }

    private func resolve(_ result: TranscriptionResult?) {
        guard let continuation = completion else { return }
        completion = nil
        watchdog?.cancel()
        watchdog = nil
        continuation.resume(returning: result)
    }

    private func printMetrics(load: TimeInterval?, stop: TimeInterval?, finalLength: Int) {
        let first = firstPartialAt.flatMap { partial in audioStartedAt.map { partial - $0 } }
        print("metrics: model_load_ms=\(milliseconds(load)) partial_updates=\(partialCount) first_partial_ms=\(milliseconds(first)) stop_to_final_ms=\(milliseconds(stop)) final_length=\(finalLength)")
        print("timing: first_partial_ms is measured from first ingest; n/a means the event did not occur")
    }

    private func milliseconds(_ seconds: TimeInterval?) -> String {
        seconds.map { String(format: "%.1f", $0 * 1_000) } ?? "n/a"
    }
}
