import Foundation
import ASRSupport
import SonioxASR
import TalkerCommonSync

/// Runs several engines in parallel during one recording and routes the final
/// result by language (`LanguageRouter`). Conforms to `SpeechBackend`, so
/// `AppDelegate` drives it exactly like a single engine.
///
/// Capture is converged onto ONE shared `AudioTapHub` (spec §1): a single
/// `AVAudioEngine` + mic tap whose PCM is pushed to every engine via `ingest`.
/// The composite owns the hub and drives the three-phase start so capture only
/// begins once every engine's session state is reset:
///   1. `beginSession` on every engine (reset state, ready to accept audio)
///   2. `hub.startCapture` (one tap goes live)
///   3. `openStream` on every engine (audio buffered during setup then flushes)
///
/// - Only the **primary** engine's partials reach the HUD; audio level comes
///   from the hub (one RMS). Secondary engines run silently.
/// - A **secondary** engine's error is non-fatal (logged). Only the primary
///   engine's (and the hub's capture) error is forwarded as fatal.
/// - On `stop()`, `hub.stopCapture()` removes the tap and drains the tail first,
///   then every engine finishes in parallel and `LanguageRouter.pickBest`
///   chooses whose transcript to hand back.
///
/// `hub` is injected (nil in unit tests, which exercise routing with canned
/// mock backends and no real capture).
final class MultiEngineBackend: SpeechBackend, @unchecked Sendable {
    private let entries: [(engine: Engine, backend: PushCaptureEngine)]
    private let primary: Engine
    private let router: LanguageRouter
    private let hub: AudioTapHub?

    /// The live session's stream continuation, set in `start()`, yielded to from
    /// the engine callbacks / capture, and finished by `stop()` / `cancel()`.
    /// Written only from `start()` on the main actor; the `stop()`/`cancel()`
    /// tasks read it after that write — no off-main-actor writes, which is what
    /// makes the `@unchecked Sendable` access pattern safe.
    private var continuation: AsyncStream<RecordingEvent>.Continuation?
    /// The task that runs `beginAllSessions` + capture start + `openStream`.
    /// `stop()` / `cancel()` await it so they never route/teardown before the
    /// session has actually begun (replaces the old hub-less start semaphore).
    /// Written only from `start()` on the main actor; the `stop()`/`cancel()`
    /// tasks read it after that write — no off-main-actor writes, which is what
    /// makes the `@unchecked Sendable` access pattern safe.
    private var startTask: Task<Void, Never>?

    /// Online language signal (QUA-153): the language-faithful classifier engine
    /// emits Latin/Han *during* recording via its partials, so by the time the
    /// user stops we already know the language — we don't have to wait for that
    /// engine's FINAL transcript just to classify. Holds the latest cumulative
    /// `PartialTranscript.combined` from `router.classifierEngine`; read once at
    /// stop. Thread-safe: written from partial callbacks, read at stop.
    private let onlineSignal = OnlineLanguageSignal()

    /// Latest cumulative classifier partial, guarded by a lock. `PartialTranscript`
    /// fields are cumulative, so the most recent `combined` is the whole transcript
    /// so far — no cross-frame accumulation needed.
    private final class OnlineLanguageSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var latest = ""
        func reset() { lock.lock(); latest = ""; lock.unlock() }
        func update(_ text: String) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }   // never overwrite a real signal with blank
            lock.lock(); latest = t; lock.unlock()
        }
        var text: String? {
            lock.lock(); defer { lock.unlock() }
            return latest.isEmpty ? nil : latest
        }
    }

    /// - Parameters:
    ///   - entries: the active engines and their backends (must be non-empty).
    ///   - primary: the HUD-driving engine; forced into `entries` if missing.
    ///   - router: language router whose slots index into `entries`.
    ///   - hub: the shared capture hub, or nil to skip real capture (tests).
    init(entries: [(engine: Engine, backend: PushCaptureEngine)],
         primary: Engine,
         router: LanguageRouter,
         hub: AudioTapHub? = nil) {
        precondition(!entries.isEmpty, "MultiEngineBackend needs at least one engine")
        self.entries = entries
        self.primary = entries.contains(where: { $0.engine == primary }) ? primary : entries[0].engine
        self.router = router
        self.hub = hub
    }

    /// Build from Preferences: one backend per active engine, primary derived
    /// from the current language, router from the configured slots, and the
    /// single shared `AudioTapHub` fed from each backend's capture sink.
    static func fromPreferences(_ prefs: Preferences) -> SpeechBackend {
        let active = prefs.activeEngines
        let primary = prefs.primaryEngine(forLanguage: prefs.language)
        let engines = active.isEmpty ? [primary] : active

        let entries = engines.map { engine in
            (engine: engine, backend: SpeechBackendFactory.make(engine: engine, language: prefs.language))
        }
        let router = LanguageRouter(chineseEngine: prefs.chineseEngine,
                                    englishEngine: prefs.englishEngine,
                                    mixedEngine: prefs.mixedEngine)

        // One tap, fanned out to each engine's sink: int16 PCM for Doubao/Soniox,
        // native buffers for Apple. The shared WAV is the Soniox-async upload
        // payload and nothing else reads it (retranscribe was removed), so write
        // it only when Soniox async is actually active — Doubao-only and
        // Soniox-realtime sessions skip the per-buffer disk I/O.
        var pcmSinks: [AudioTapHub.PCMSink] = []
        var bufferSinks: [AudioTapHub.BufferSink] = []
        for entry in entries {
            if let p = entry.backend as? PCMCaptureEngine {
                pcmSinks.append { p.ingest($0) }
            } else if let b = entry.backend as? BufferCaptureEngine {
                bufferSinks.append { b.ingest($0) }
            } else {
                // Every shipping engine is either PCM (Doubao/Soniox) or Buffer
                // (Apple). A PushCaptureEngine that is neither would silently get
                // NO audio — an empty transcript with no error. Make it loud.
                assertionFailure("\(entry.engine) is a PushCaptureEngine but neither PCMCaptureEngine nor BufferCaptureEngine — it would receive no audio")
                doushaLog("[MultiEngine] \(entry.engine.rawValue) has no audio sink — check its capture protocol conformance")
            }
        }
        let wantsWAV = prefs.sonioxMode == .async && entries.contains { $0.engine == .soniox }
        let hub = AudioTapHub(pcmSinks: pcmSinks, bufferSinks: bufferSinks, wantsWAV: wantsWAV)

        return MultiEngineBackend(entries: entries, primary: primary, router: router, hub: hub)
    }

    func setLanguage(_ identifier: String) {
        for entry in entries { entry.backend.setLanguage(identifier) }
    }

    func start() -> AsyncStream<RecordingEvent> {
        let (stream, cont) = AsyncStream<RecordingEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = cont
        onlineSignal.reset()   // QUA-153: fresh language signal per recording

        startTask = Task {
            // Phase 1 — reset every engine's session state BEFORE capture starts,
            // so a buffer pushed the instant the tap goes live isn't dropped.
            await self.beginAllSessions(
                onPartial: { cont.yield(.partial($0)) },
                onError:   { cont.yield(.error($0.localizedDescription)) })

            // Phase 2 — one shared mic tap (skipped in hub-less unit tests). Its
            // failure is fatal (no audio at all): tear down the just-prepared
            // engines, surface the error, finish the stream.
            if let hub = self.hub {
                do {
                    try await hub.startCapture(onLevel: { cont.yield(.audioLevel($0)) })
                } catch {
                    doushaLog("[MultiEngine] capture start failed: \(error.localizedDescription)")
                    for entry in self.entries { entry.backend.cancelSession() }
                    cont.yield(.error(error.localizedDescription))
                    cont.finish()
                    return
                }
            }

            // Phase 3 — open each engine's stream; audio buffered during setup
            // flushes once the stream is ready.
            for entry in self.entries { entry.backend.openStream() }
        }

        return stream
    }

    /// Reset every engine's session state. The primary drives the user's HUD
    /// partials + fatal errors; secondaries run silently with non-fatal (logged)
    /// errors. Shared by the real-capture and hub-less (test) start paths.
    private func beginAllSessions(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                                  onError: @escaping @Sendable (Error) -> Void) async {
        for entry in entries {
            let partialCB = partialCallback(for: entry.engine, userPartial: onPartial)
            if entry.engine == primary {
                await entry.backend.beginSession(onPartial: partialCB, onError: onError)
            } else {
                let e = entry.engine
                await entry.backend.beginSession(onPartial: partialCB, onError: { err in
                    doushaLog("[MultiEngine] secondary \(e.rawValue) error (non-fatal): \(err.localizedDescription)")
                })
            }
        }
    }

    /// Per-engine partial sink. The primary's partials drive the HUD (the user's
    /// `onPartial`); secondaries are silent (`{ _ in }`). The language-faithful
    /// classifier engine — whether primary or secondary — additionally feeds the
    /// online language signal (QUA-153), so the two roles compose when the
    /// classifier *is* the primary.
    private func partialCallback(for engine: Engine,
                                 userPartial: @escaping @Sendable (PartialTranscript) -> Void)
        -> @Sendable (PartialTranscript) -> Void {
        let silent: @Sendable (PartialTranscript) -> Void = { _ in }
        let base: @Sendable (PartialTranscript) -> Void = (engine == primary) ? userPartial : silent
        guard engine == router.classifierEngine else { return base }
        let signal = onlineSignal
        return { p in
            signal.update(p.combined)
            base(p)
        }
    }

    func stop() {
        Task {
            await self.startTask?.value          // never route before the session began
            // Remove the tap + drain the tail BEFORE the engines flush + finish,
            // so every engine's pcmBuffer holds the last buffers the user spoke.
            if let hub = self.hub { await hub.stopCapture() }
            self.routeFinalResult { result in
                self.continuation?.yield(.final(result))
                self.continuation?.finish()
            }
        }
    }

    /// Finish every engine and route by language. Early-exit: we only need the
    /// Chinese-specialist's result when the speech is actually Chinese. The
    /// language-faithful "classifier" engine (English slot — renders English as
    /// Latin, Chinese as Han) tells us which it is. So:
    ///   • classifier returns English/mixed → use it NOW, skip waiting for 豆包.
    ///   • classifier returns Chinese       → wait for the Chinese engine.
    ///
    /// QUA-153 — online language judgement: if the classifier streamed enough
    /// partials *during* recording, we already know the language before any
    /// final arrives (`onlineChosen`). Then we don't even wait for the
    /// classifier's FINAL transcript to classify — we wait only for the chosen
    /// engine. The win is Chinese: instead of waiting for the slower of
    /// {Soniox-final, 豆包-final}, we wait for 豆包 alone. With no online signal
    /// (silence / instant stop), we fall back to the classifier-final logic.
    ///
    /// All engines' finish() are still called (to release WS/recognizer); we just
    /// don't *wait* on results we won't use. `completion` fires exactly once.
    private func routeFinalResult(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        // QUA-153: language decided online (from recording-time partials), if any.
        let onlineChosen: Engine? = onlineSignal.text.map { router.slot(forScoreText: $0) }
        let collector = FinalResultCollector(
            primary: primary,
            router: router,
            orderedEngines: entries.map(\.engine),
            onlineChosen: onlineChosen,
            remaining: entries.count,
            completion: completion
        )
        for entry in entries {
            let engine = entry.engine
            entry.backend.finish { result in
                collector.record(engine: engine, result: result)
            }
        }
    }

    /// Collects each engine's final transcript (from arbitrary backend threads),
    /// applies the QUA-153 online / classifier routing the instant enough results
    /// are in, and fires `completion` exactly once. All mutable state is guarded by
    /// `lock`; the engine `finish` completions are `@Sendable` and capture this
    /// reference (a `Sendable` class) rather than raw vars.
    private final class FinalResultCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Engine: TranscriptionResult] = [:]
        private var timings: [Engine: TimeInterval] = [:]
        private var finished = false
        private var remaining: Int
        private let t0 = Date()

        private let primary: Engine
        private let router: LanguageRouter
        private let classifier: Engine
        private let orderedEngines: [Engine]
        private let onlineChosen: Engine?
        private let completion: @Sendable (TranscriptionResult) -> Void

        init(primary: Engine,
             router: LanguageRouter,
             orderedEngines: [Engine],
             onlineChosen: Engine?,
             remaining: Int,
             completion: @escaping @Sendable (TranscriptionResult) -> Void) {
            self.primary = primary
            self.router = router
            self.classifier = router.classifierEngine
            self.orderedEngines = orderedEngines
            self.onlineChosen = onlineChosen
            self.remaining = remaining
            self.completion = completion
        }

        /// One engine's final transcript arrived. Routes + fires `completion` once.
        func record(engine: Engine, result: TranscriptionResult) {
            lock.lock()
            defer { lock.unlock() }
            results[engine] = result
            timings[engine] = Date().timeIntervalSince(t0)
            remaining -= 1
            let allDone = remaining == 0
            guard !finished else { return }

            if let chosen = onlineChosen {
                // Language already known from online partials — wait only for
                // the chosen engine; ignore the classifier's final entirely.
                if textOf(chosen) != nil {
                    finish(chosen)
                } else if allDone {
                    finish(firstNonEmpty([primary] + orderedEngines) ?? primary)  // chosen empty/failed
                }
                // else: chosen engine still pending — wait for it.
            } else if let cText = textOf(classifier) {
                // We can route: classify the faithful engine's transcript.
                let chosen = router.slot(forScoreText: cText)
                if textOf(chosen) != nil {
                    finish(chosen)                                  // routed engine's result is in
                } else if allDone {
                    finish(firstNonEmpty([primary] + orderedEngines) ?? primary)  // routed engine empty/failed
                }
                // else: routed (Chinese) engine still pending — wait for it.
            } else if allDone {
                // Classifier produced nothing — fall back over whatever we have.
                finish(firstNonEmpty([primary] + orderedEngines) ?? primary)
            }
            // else: classifier still pending — wait for it.
        }

        // The helpers below assume `lock` is already held (only `record` calls them).
        private func textOf(_ e: Engine) -> String? {
            guard let t = results[e]?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty else { return nil }
            return t
        }

        private func firstNonEmpty(_ order: [Engine]) -> Engine? { order.first { textOf($0) != nil } }

        private func finish(_ engine: Engine) {
            finished = true
            let elapsed = Date().timeIntervalSince(t0)
            let perEngine = orderedEngines.map { e -> String in
                let len = textOf(e)?.count ?? -1
                let ms = timings[e].map { Int($0 * 1000) } ?? -1
                return "\(e.rawValue)(\(len)ch,\(ms)ms\(e == primary ? ",P" : "")\(e == classifier ? ",CLS" : ""))"
            }.joined(separator: " ")
            let result = results[engine] ?? TranscriptionResult(
                text: "", audioDuration: 0, lastResponseAge: nil,
                lastTranscriptAge: nil)
            let onlineTag = onlineChosen.map { "online=\($0.rawValue)" } ?? "online=none"
            doushaLog("[MultiEngine] stop=\(Int(elapsed * 1000))ms | \(perEngine) | \(onlineTag) | picked=\(engine.rawValue) len=\(result.text.count)")
            // Yielding to the AsyncStream is thread-safe from any thread; the
            // .final crosses to the main actor via the controller's `for await`,
            // so the explicit main-hop here is redundant.
            completion(result)
        }
    }

    func cancel() {
        // Stop the consumer immediately; engine/hub teardown happens after the
        // start task settles so we never cancel sessions that haven't begun.
        continuation?.finish()
        Task {
            await self.startTask?.value
            if let hub = self.hub { await hub.cancelCapture() }
            for entry in self.entries { entry.backend.cancelSession() }
        }
    }
}
