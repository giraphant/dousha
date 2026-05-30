import Foundation
import ASRSupport
import TalkerCommonSync

/// Runs several `SpeechBackend`s in parallel during one recording and routes the
/// final result by language (`LanguageRouter`). Conforms to `SpeechBackend`, so
/// `AppDelegate` drives it exactly like a single engine.
///
/// - Only the **primary** engine's partials + audio level reach the HUD; the
///   others run silently.
/// - A **secondary** engine's error is non-fatal (logged, that engine just
///   drops out of routing). Only the primary engine's error is forwarded as
///   fatal — matching single-engine behavior.
/// - On `stop()`, every engine is stopped in parallel; once all return,
///   `LanguageRouter.pickBest` chooses whose transcript to hand back.
///
/// Each composed backend keeps its own audio capture (two mic taps when two
/// engines are active). Consolidating onto one shared tap (`AudioTapHub`) is a
/// behavior-neutral follow-up; see the Plan C doc.
final class MultiEngineBackend: SpeechBackend {
    private let entries: [(engine: Engine, backend: SpeechBackend)]
    private let primary: Engine
    private let router: LanguageRouter

    /// - Parameters:
    ///   - entries: the active engines and their backends (must be non-empty).
    ///   - primary: the HUD-driving engine; forced into `entries` if missing.
    ///   - router: language router whose slots index into `entries`.
    init(entries: [(engine: Engine, backend: SpeechBackend)],
         primary: Engine,
         router: LanguageRouter) {
        precondition(!entries.isEmpty, "MultiEngineBackend needs at least one engine")
        self.entries = entries
        self.primary = entries.contains(where: { $0.engine == primary }) ? primary : entries[0].engine
        self.router = router
    }

    /// Build from Preferences: one backend per active engine, primary derived
    /// from the current language, router from the configured slots.
    static func fromPreferences(_ prefs: Preferences) -> SpeechBackend {
        let active = prefs.activeEngines
        let primary = prefs.primaryEngine(forLanguage: prefs.language)

        // Degenerate single-engine: skip the composite entirely (zero overhead).
        if active.count <= 1 {
            return SpeechBackendFactory.make(engine: active.first ?? primary,
                                             language: prefs.language)
        }

        let entries = active.map { engine in
            (engine: engine, backend: SpeechBackendFactory.make(engine: engine, language: prefs.language))
        }
        let router = LanguageRouter(chineseEngine: prefs.chineseEngine,
                                    englishEngine: prefs.englishEngine,
                                    mixedEngine: prefs.mixedEngine)
        return MultiEngineBackend(entries: entries, primary: primary, router: router)
    }

    func setLanguage(_ identifier: String) {
        for entry in entries { entry.backend.setLanguage(identifier) }
    }

    func start(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
               onAudioLevel: @escaping @Sendable (Float) -> Void,
               onError: @escaping @Sendable (Error) -> Void) {
        for entry in entries {
            if entry.engine == primary {
                // Primary drives the HUD and is the only fatal error source.
                entry.backend.start(onPartial: onPartial,
                                    onAudioLevel: onAudioLevel,
                                    onError: onError)
            } else {
                // Secondary: silent, and its errors must not abort the recording.
                let engine = entry.engine
                entry.backend.start(onPartial: { _ in },
                                    onAudioLevel: { _ in },
                                    onError: { err in
                    doushaLog("[MultiEngine] secondary \(engine.rawValue) error (non-fatal): \(err.localizedDescription)")
                })
            }
        }
    }

    func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [Engine: TranscriptionResult] = [:]
        var timings: [Engine: TimeInterval] = [:]
        let t0 = Date()

        for entry in entries {
            let engine = entry.engine
            group.enter()
            entry.backend.stop { result in
                lock.lock()
                results[engine] = result
                timings[engine] = Date().timeIntervalSince(t0)
                lock.unlock()
                group.leave()
            }
        }

        let primary = self.primary
        let router = self.router
        let orderedEngines = entries.map(\.engine)
        group.notify(queue: .main) {
            let textMap = results.mapValues {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let elapsed = Date().timeIntervalSince(t0)
            // Per-engine: transcript length + when it returned (ms after stop).
            let perEngine = orderedEngines.map { e -> String in
                let len = textMap[e]?.count ?? -1
                let ms = timings[e].map { Int($0 * 1000) } ?? -1
                return "\(e.rawValue)(len=\(len),\(ms)ms\(e == primary ? ",PRIMARY" : ""))"
            }.joined(separator: " ")
            if let pick = router.pickBest(results: textMap, primary: primary),
               let chosen = results[pick.engine] {
                qua145Debug("[MultiEngine] stop=\(Int(elapsed * 1000))ms | \(perEngine) | picked=\(pick.engine.rawValue)")
                doushaLog("[MultiEngine] picked \(pick.engine.rawValue) (len=\(chosen.text.count)) from \(results.count) engines")
                completion(chosen)
            } else {
                qua145Debug("[MultiEngine] stop=\(Int(elapsed * 1000))ms | \(perEngine) | picked=NONE(all empty)")
                // Everything came back empty — hand back the primary's (empty)
                // result so the caller's empty-text guard runs as usual.
                let fallback = results[primary] ?? results.values.first
                    ?? TranscriptionResult(text: "", audioDuration: 0,
                                           lastResponseAge: nil, lastTranscriptAge: nil,
                                           savedAudioURL: nil)
                completion(fallback)
            }
        }
    }

    func cancel() {
        for entry in entries { entry.backend.cancel() }
    }
}
