import Foundation
import ASRSupport
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
    private let entries: [(engine: Engine, backend: SpeechBackend)]
    private let primary: Engine
    private let router: LanguageRouter
    private let hub: AudioTapHub?

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
    init(entries: [(engine: Engine, backend: SpeechBackend)],
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
        // native buffers for Apple. The shared WAV is written whenever a PCM
        // engine is active (it's the Soniox-async upload payload + future
        // retranscribe side recording).
        var pcmSinks: [AudioTapHub.PCMSink] = []
        var bufferSinks: [AudioTapHub.BufferSink] = []
        for entry in entries {
            if let p = entry.backend as? PCMCaptureEngine {
                pcmSinks.append { p.ingest($0) }
            } else if let b = entry.backend as? BufferCaptureEngine {
                bufferSinks.append { b.ingest($0) }
            }
        }
        let wantsWAV = entries.contains { $0.engine == .doubao || $0.engine == .soniox }
        let hub = AudioTapHub(pcmSinks: pcmSinks, bufferSinks: bufferSinks, wantsWAV: wantsWAV)

        return MultiEngineBackend(entries: entries, primary: primary, router: router, hub: hub)
    }

    func setLanguage(_ identifier: String) {
        for entry in entries { entry.backend.setLanguage(identifier) }
    }

    func start(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
               onAudioLevel: @escaping @Sendable (Float) -> Void,
               onError: @escaping @Sendable (Error) -> Void) {
        onlineSignal.reset()   // QUA-153: fresh language signal per recording
        guard let hub else {
            // Hub-less path (unit tests / degenerate): each backend self-reports.
            for entry in entries {
                startLeaf(entry, onPartial: onPartial, onAudioLevel: onAudioLevel, onError: onError)
            }
            return
        }

        let entries = self.entries
        let primary = self.primary
        Task {
            // Phase 1 — reset every engine's session state BEFORE capture starts,
            // so a buffer pushed the instant the tap goes live isn't dropped.
            for entry in entries {
                guard let engine = entry.backend as? PushCaptureEngine else { continue }
                let partialCB = self.partialCallback(for: entry.engine, userPartial: onPartial)
                if entry.engine == primary {
                    await engine.beginSession(onPartial: partialCB, onError: onError)
                } else {
                    let e = entry.engine
                    await engine.beginSession(onPartial: partialCB, onError: { err in
                        doushaLog("[MultiEngine] secondary \(e.rawValue) error (non-fatal): \(err.localizedDescription)")
                    })
                }
            }

            // Phase 2 — one shared mic tap. Its failure is fatal (no audio at
            // all): tear down the just-prepared engines so they don't sit through
            // a finish-wait timeout, then surface the error.
            do {
                try await hub.startCapture(onLevel: onAudioLevel)
            } catch {
                doushaLog("[MultiEngine] capture start failed: \(error.localizedDescription)")
                for entry in entries {
                    (entry.backend as? PushCaptureEngine)?.cancelSession()
                }
                DispatchQueue.main.async { onError(error) }
                return
            }

            // Phase 3 — open each engine's stream; audio buffered during setup
            // flushes once the stream is ready.
            for entry in entries {
                (entry.backend as? PushCaptureEngine)?.openStream()
            }
        }
    }

    /// Hub-less start for a single entry: primary drives HUD + fatal errors,
    /// secondaries run silently with non-fatal errors. Preserves the original
    /// per-engine `SpeechBackend.start` contract used by the mock tests.
    private func startLeaf(_ entry: (engine: Engine, backend: SpeechBackend),
                           onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                           onAudioLevel: @escaping @Sendable (Float) -> Void,
                           onError: @escaping @Sendable (Error) -> Void) {
        let partialCB = partialCallback(for: entry.engine, userPartial: onPartial)
        if entry.engine == primary {
            entry.backend.start(onPartial: partialCB, onAudioLevel: onAudioLevel, onError: onError)
        } else {
            let e = entry.engine
            entry.backend.start(onPartial: partialCB, onAudioLevel: { _ in }, onError: { err in
                doushaLog("[MultiEngine] secondary \(e.rawValue) error (non-fatal): \(err.localizedDescription)")
            })
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

    func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        guard let hub else {
            routeFinalResult(completion: completion)
            return
        }
        // Remove the tap + drain the tail BEFORE the engines flush + finish, so
        // every engine's pcmBuffer holds the last buffers the user spoke.
        Task {
            await hub.stopCapture()
            routeFinalResult(completion: completion)
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
        let lock = NSLock()
        var results: [Engine: TranscriptionResult] = [:]
        var timings: [Engine: TimeInterval] = [:]
        var finished = false
        var remaining = entries.count
        let t0 = Date()

        let primary = self.primary
        let router = self.router
        let classifier = router.classifierEngine
        let orderedEngines = entries.map(\.engine)

        // QUA-153: language decided online (from recording-time partials), if any.
        let onlineChosen: Engine? = onlineSignal.text.map { router.slot(forScoreText: $0) }

        // All reads/writes below happen under `lock`.
        func textOf(_ e: Engine) -> String? {
            guard let t = results[e]?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty else { return nil }
            return t
        }
        func firstNonEmpty(_ order: [Engine]) -> Engine? { order.first { textOf($0) != nil } }

        func finish(_ engine: Engine) {
            finished = true
            let elapsed = Date().timeIntervalSince(t0)
            let perEngine = orderedEngines.map { e -> String in
                let len = textOf(e)?.count ?? -1
                let ms = timings[e].map { Int($0 * 1000) } ?? -1
                return "\(e.rawValue)(\(len)ch,\(ms)ms\(e == primary ? ",P" : "")\(e == classifier ? ",CLS" : ""))"
            }.joined(separator: " ")
            let result = results[engine] ?? TranscriptionResult(
                text: "", audioDuration: 0, lastResponseAge: nil,
                lastTranscriptAge: nil, savedAudioURL: nil)
            let onlineTag = onlineChosen.map { "online=\($0.rawValue)" } ?? "online=none"
            qua145Debug("[MultiEngine] stop=\(Int(elapsed * 1000))ms | \(perEngine) | \(onlineTag) | picked=\(engine.rawValue)")
            doushaLog("[MultiEngine] picked \(engine.rawValue) len=\(result.text.count)")
            DispatchQueue.main.async { completion(result) }
        }

        for entry in entries {
            let engine = entry.engine
            entry.backend.stop { result in
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
        }
    }

    func cancel() {
        if let hub { Task { await hub.cancelCapture() } }
        for entry in entries { entry.backend.cancel() }
    }
}
