import XCTest
import Foundation
import ASRSupport
@testable import Dousha

final class MultiEngineBackendTests: XCTestCase {

    /// Canned-result push engine for testing the composite without audio/network.
    private final class MockBackend: PushCaptureEngine, @unchecked Sendable {
        let result: TranscriptionResult
        let errorOnStart: Error?
        let stopDelay: TimeInterval
        /// Emitted as a cumulative partial the instant start() is called, to
        /// drive the online language signal in QUA-153 tests.
        let partialOnStart: String?
        private(set) var startCalled = false
        private(set) var cancelCalled = false
        /// Captured in `beginSession` so a test can drive partials on demand
        /// (QUA-180 fallback timing tests), mirroring an engine emitting mid-session.
        private var partialSink: (@Sendable (PartialTranscript) -> Void)?

        init(text: String, errorOnStart: Error? = nil, stopDelay: TimeInterval = 0,
             partialOnStart: String? = nil) {
            self.result = TranscriptionResult(text: text)
            self.errorOnStart = errorOnStart
            self.stopDelay = stopDelay
            self.partialOnStart = partialOnStart
        }
        func setLanguage(_ identifier: String) {}
        func beginSession(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                          onError: @escaping @Sendable (Error) -> Void) async {
            startCalled = true
            partialSink = onPartial
            if let p = partialOnStart {
                onPartial(PartialTranscript(finalText: p, interimText: ""))
            }
            if let e = errorOnStart { onError(e) }
        }
        /// Emit a cumulative partial mid-session (after `beginSession`).
        func emit(_ text: String) {
            partialSink?(PartialTranscript(finalText: text, interimText: ""))
        }
        func openStream() {}
        func finish(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
            if stopDelay > 0 {
                let r = result
                DispatchQueue.global().asyncAfter(deadline: .now() + stopDelay) { completion(r) }
            } else {
                completion(result)
            }
        }
        func cancelSession() { cancelCalled = true }
    }

    private let router = LanguageRouter(chineseEngine: .doubao,
                                        englishEngine: .soniox,
                                        mixedEngine: .soniox)

    /// PCM push engine that records every ingested chunk (replay tests).
    private final class MockPCMBackend: PCMCaptureEngine, @unchecked Sendable {
        let result: TranscriptionResult
        private let lock = NSLock()
        private var _ingested = Data()
        var ingested: Data { lock.lock(); defer { lock.unlock() }; return _ingested }
        init(text: String) { self.result = TranscriptionResult(text: text) }
        func setLanguage(_ identifier: String) {}
        func beginSession(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                          onError: @escaping @Sendable (Error) -> Void) async {}
        func openStream() {}
        func ingest(_ pcm: Data) { lock.lock(); _ingested.append(pcm); lock.unlock() }
        func finish(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
            completion(result)
        }
        func cancelSession() {}
    }

    /// Writes a small valid WAV (16 kHz mono s16) and returns (url, pcmByteCount).
    private func makeTestWAV(samples: Int) throws -> (URL, Int) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-\(UUID().uuidString).wav")
        let writer = try WavFileWriter(url: url, sampleRate: 16_000, channels: 1)
        var data = [Int16](repeating: 1_000, count: samples)
        data.withUnsafeBufferPointer { writer.append(int16Samples: $0.baseAddress!, count: $0.count) }
        try writer.close()
        return (url, samples * 2)
    }

    func testReplay_pushesWholeWavBeforeFinish() async throws {
        // 4000 samples = 8000 bytes → 2 full 3200-byte chunks + one 1600-byte tail.
        let (url, byteCount) = try makeTestWAV(samples: 4_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let mock = MockPCMBackend(text: "replayed")
        let multi = MultiEngineBackend(entries: [(.soniox, mock)], primary: .soniox,
                                       router: router, hub: nil, replayWAV: url)
        let result = await finalResult(multi)
        XCTAssertEqual(result.text, "replayed")
        // stop() awaited startTask (which includes the push), so by the time the
        // final arrived every byte must have been ingested.
        XCTAssertEqual(mock.ingested.count, byteCount)
    }

    func testReplay_missingWavYieldsStreamError() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).wav")
        let mock = MockPCMBackend(text: "")
        let multi = MultiEngineBackend(entries: [(.soniox, mock)], primary: .soniox,
                                       router: router, hub: nil, replayWAV: url)
        let stream = multi.start()
        multi.stop()
        var sawError = false
        for await event in stream {
            if case .error = event { sawError = true }
            if case .final = event { break }
        }
        XCTAssertTrue(sawError)
        XCTAssertTrue(mock.ingested.isEmpty)
    }

    /// Drives the new stream API to completion and returns the routed final
    /// result. `start()` sets up the sessions (mock partials/errors emitted
    /// synchronously inside beginSession); `stop()` awaits that setup, routes,
    /// and yields the terminal `.final`. We consume the stream until it arrives.
    private func finalResult(_ multi: MultiEngineBackend) async -> TranscriptionResult {
        let stream = multi.start()
        multi.stop()
        for await event in stream {
            if case .final(let r) = event { return r }
        }
        return TranscriptionResult(text: "<no final>")
    }

    /// Polls `cond` until true or timeout (non-MainActor; for the cancel test).
    private func eventually(_ cond: @escaping () -> Bool, timeout: TimeInterval = 1) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out"); return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func testStop_routesChineseDominantToDoubao() async {
        // Chinese speech: Soniox (the faithful classifier) also renders Han, so it
        // reads as Chinese → route to 豆包's cleaner Chinese transcript.
        let multi = MultiEngineBackend(
            entries: [(.doubao, MockBackend(text: "你好世界你好啊")), (.soniox, MockBackend(text: "你好世界"))],
            primary: .doubao, router: router)
        let result = await finalResult(multi)
        XCTAssertEqual(result.text, "你好世界你好啊")
    }

    func testStop_englishMangledByDoubao_stillRoutesToSoniox() async {
        // User spoke English; 豆包 homophone-mangles to Han (looks Chinese), Soniox
        // shows real English. Classifying on Soniox routes correctly to Soniox.
        let multi = MultiEngineBackend(
            entries: [(.doubao, MockBackend(text: "普莱斯泰勒")), (.soniox, MockBackend(text: "price tailor please"))],
            primary: .doubao, router: router)
        let result = await finalResult(multi)
        XCTAssertEqual(result.text, "price tailor please")
    }

    func testStop_routesEnglishDominantToSoniox() async {
        let multi = MultiEngineBackend(
            entries: [(.doubao, MockBackend(text: "皮森哈喽")), (.soniox, MockBackend(text: "Python hello there"))],
            primary: .soniox, router: router)
        let result = await finalResult(multi)
        XCTAssertEqual(result.text, "Python hello there")
    }

    func testStop_chosenEngineEmpty_fallsThroughToNonEmpty() async {
        // Chinese-dominant score → chosen doubao, but doubao empty → fall through.
        let multi = MultiEngineBackend(
            entries: [(.doubao, MockBackend(text: "")), (.soniox, MockBackend(text: "你好世界你好啊"))],
            primary: .soniox, router: router)
        let result = await finalResult(multi)
        XCTAssertEqual(result.text, "你好世界你好啊")
    }

    func testStop_allEmpty_returnsEmpty() async {
        let multi = MultiEngineBackend(
            entries: [(.doubao, MockBackend(text: "")), (.soniox, MockBackend(text: ""))],
            primary: .doubao, router: router)
        let result = await finalResult(multi)
        XCTAssertTrue(result.text.isEmpty)
    }

    func testStart_secondaryErrorIsNonFatal() async {
        let soniox = MockBackend(text: "x", errorOnStart: NSError(domain: "t", code: 1))
        let doubao = MockBackend(text: "你好")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router)
        let stream = multi.start()
        multi.stop()
        var sawError = false
        for await event in stream { if case .error = event { sawError = true } }
        XCTAssertFalse(sawError, "a secondary engine's error must not reach the stream")
        XCTAssertTrue(doubao.startCalled)
        XCTAssertTrue(soniox.startCalled)
    }

    func testStart_primaryErrorAlone_isNonFatal_secondaryCarriesSession() async {
        // QUA-180: 豆包 (primary) errors at openStream (e.g. WS TLS failure), but
        // Soniox is alive. The error must NOT be fatal — the session keeps running
        // and the secondary's transcript is returned, not a dropped recording.
        let doubao = MockBackend(text: "", errorOnStart: NSError(domain: "t", code: 2))
        let soniox = MockBackend(text: "ok")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router)
        let stream = multi.start()
        multi.stop()
        var sawError = false
        var final: TranscriptionResult?
        for await event in stream {
            if case .error = event { sawError = true }
            if case .final(let r) = event { final = r }
        }
        XCTAssertFalse(sawError, "a primary error must not be fatal while a secondary is alive")
        XCTAssertEqual(final?.text, "ok", "the secondary must carry the final transcript")
    }

    func testStart_allEnginesError_isFatal() async {
        // Only when EVERY engine fails (e.g. full network loss) is the error fatal.
        let doubao = MockBackend(text: "", errorOnStart: NSError(domain: "t", code: 2))
        let soniox = MockBackend(text: "", errorOnStart: NSError(domain: "t", code: 3))
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router)
        let stream = multi.start()
        multi.stop()
        var sawError = false
        for await event in stream { if case .error = event { sawError = true } }
        XCTAssertTrue(sawError, "with every engine down, the error must be forwarded as fatal")
    }

    func testStop_englishEarlyExit_doesNotWaitForSlowChineseEngine() async {
        // 豆包 is slow (1s); Soniox (classifier) returns English instantly. The
        // result must come back via Soniox WITHOUT waiting the full second.
        let doubao = MockBackend(text: "普莱斯", stopDelay: 1.0)
        let soniox = MockBackend(text: "price please now")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router)
        let t0 = Date()
        let result = await finalResult(multi)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertEqual(result.text, "price please now")
        XCTAssertLessThan(elapsed, 0.5, "English should early-exit via Soniox, not wait for the 1s 豆包")
    }

    func testStop_chineseWaitsForChineseEngine_evenIfSlow() async {
        // Soniox (classifier) returns Chinese (Han) instantly → route to 豆包, which
        // is slow (0.4s). Must WAIT for 豆包 and return its cleaner transcript.
        let doubao = MockBackend(text: "今天天气很好啊", stopDelay: 0.4)
        let soniox = MockBackend(text: "今天天气很好")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router)
        let t0 = Date()
        let result = await finalResult(multi)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertEqual(result.text, "今天天气很好啊")
        XCTAssertGreaterThan(elapsed, 0.3, "Chinese must wait for 豆包")
    }

    // MARK: - QUA-153 online language judgement

    func testOnline_chineseKnownDuringRecording_waitsOnlyForDoubao_notSlowClassifier() async {
        // Soniox (classifier) streams a Chinese partial DURING recording, so the
        // language is known before any final arrives. 豆包 finals instantly; Soniox's
        // FINAL is deliberately slow (1s). The online path must route to 豆包 and
        // return WITHOUT waiting for the slow classifier final — the QUA-153 win.
        let doubao = MockBackend(text: "今天天气很好啊")
        let soniox = MockBackend(text: "今天天气很好", stopDelay: 1.0,
                                 partialOnStart: "今天天气很好")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router)
        let t0 = Date()
        let result = await finalResult(multi)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertEqual(result.text, "今天天气很好啊")
        XCTAssertLessThan(elapsed, 0.5,
            "Chinese known online must wait only for 豆包, not the slow Soniox final")
    }

    func testOnline_englishKnownDuringRecording_routesToSoniox_skipsDoubao() async {
        // Soniox streams an English partial during recording → online language is
        // English → route to Soniox and don't wait for the slow 豆包.
        let doubao = MockBackend(text: "皮森哈喽", stopDelay: 1.0)
        let soniox = MockBackend(text: "Python hello there",
                                 partialOnStart: "Python hello there")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router)
        let t0 = Date()
        let result = await finalResult(multi)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertEqual(result.text, "Python hello there")
        XCTAssertLessThan(elapsed, 0.5, "English known online must skip the slow 豆包")
    }

    func testOnline_chosenEngineEmpty_fallsThroughToNonEmpty() async {
        // Online says Chinese → chosen 豆包, but 豆包 finals empty → fall through to
        // any non-empty result (Soniox).
        let doubao = MockBackend(text: "")
        let soniox = MockBackend(text: "今天天气很好", partialOnStart: "今天天气很好")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router)
        let result = await finalResult(multi)
        XCTAssertEqual(result.text, "今天天气很好")
    }

    func testOnline_noPartials_fallsBackToClassifierFinalLogic() async {
        // No partials streamed (silence / instant stop) → no online signal → the
        // existing classifier-final routing must still apply.
        let doubao = MockBackend(text: "你好世界你好啊")
        let soniox = MockBackend(text: "你好世界")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router)
        let result = await finalResult(multi)
        XCTAssertEqual(result.text, "你好世界你好啊")
    }

    // MARK: - QUA-180 HUD fallback to secondary

    /// Collects every `.partial` text the HUD would render, driving the stream to
    /// its terminal `.final`.
    private func hudPartials(_ multi: MultiEngineBackend) async -> [String] {
        let stream = multi.start()
        multi.stop()
        var partials: [String] = []
        for await event in stream {
            switch event {
            case .partial(let p): partials.append(p.combined)
            case .final: return partials
            default: break
            }
        }
        return partials
    }

    func testHUD_primarySilent_fallsBackToSecondaryPartial() async {
        // 豆包 (primary) emits no partial — dead WS, frames=0. Soniox does. With a
        // zero-length fallback window the secondary's partial must reach the HUD,
        // so the live-subtitle area is no longer blank (QUA-180).
        let doubao = MockBackend(text: "")                                  // no partialOnStart
        let soniox = MockBackend(text: "你好", partialOnStart: "你好世界实时字幕")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router,
                                       hudFallbackSeconds: 0)
        let partials = await hudPartials(multi)
        XCTAssertTrue(partials.contains("你好世界实时字幕"),
                      "secondary partial must drive the HUD when the primary is silent")
    }

    func testHUD_primaryActive_secondaryPartialSuppressed() async {
        // Both engines emit partials and the fallback window is wide. The active
        // primary owns the HUD; the secondary's partial must NOT appear.
        let doubao = MockBackend(text: "你好", partialOnStart: "豆包实时字幕")
        let soniox = MockBackend(text: "你好", partialOnStart: "搜你克斯实时字幕")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router,
                                       hudFallbackSeconds: 10)
        let partials = await hudPartials(multi)
        XCTAssertTrue(partials.contains("豆包实时字幕"), "primary partial must drive the HUD")
        XCTAssertFalse(partials.contains("搜你克斯实时字幕"),
                       "an active primary must suppress the secondary's HUD partials")
    }

    func testHUD_primaryResumesAfterFallback_reclaimsHUD() async {
        // Full lifecycle: 豆包 silent past the window → Soniox drives the HUD; 豆包
        // then resumes → its partial reclaims the HUD AND re-suppresses the next
        // secondary partial (the liveness clock reset). QUA-180's core semantic.
        let doubao = MockBackend(text: "你好")
        let soniox = MockBackend(text: "你好")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router,
                                       hudFallbackSeconds: 0.2)
        let stream = multi.start()
        // Consume partials concurrently while we drive the engines below.
        let collected = Task { () -> [String] in
            var out: [String] = []
            for await event in stream {
                switch event {
                case .partial(let p): out.append(p.combined)
                case .final: return out
                default: break
                }
            }
            return out
        }

        await eventually({ doubao.startCalled && soniox.startCalled })
        try? await Task.sleep(nanoseconds: 300_000_000)   // outlast the 0.2s silence window

        soniox.emit("副字幕回退")     // 豆包 silent → secondary drives the HUD
        doubao.emit("主字幕恢复")     // 豆包 back → reclaims the HUD, resets the clock
        soniox.emit("副字幕被压制")   // 豆包 just active → secondary suppressed again

        multi.stop()
        let partials = await collected.value
        XCTAssertTrue(partials.contains("副字幕回退"),
                      "secondary must drive the HUD while the primary is silent")
        XCTAssertTrue(partials.contains("主字幕恢复"),
                      "a resumed primary partial must reclaim the HUD")
        XCTAssertFalse(partials.contains("副字幕被压制"),
                       "a freshly-resumed primary must re-suppress the secondary")
    }

    func testHUD_primaryError_secondaryTakesOverImmediately() async {
        // Primary errors at openStream → HUD must switch to the secondary on its
        // next partial WITHOUT waiting out the silence window (markPrimaryFailed).
        // The window is huge so only the error path can trigger the fallback.
        let doubao = MockBackend(text: "", errorOnStart: NSError(domain: "t", code: 2))
        let soniox = MockBackend(text: "你好")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router,
                                       hudFallbackSeconds: 100)
        let stream = multi.start()
        let collected = Task { () -> [String] in
            var out: [String] = []
            for await event in stream {
                switch event {
                case .partial(let p): out.append(p.combined)
                case .final: return out
                default: break
                }
            }
            return out
        }
        await eventually({ doubao.startCalled && soniox.startCalled })
        soniox.emit("副字幕立即接管")
        multi.stop()
        let partials = await collected.value
        XCTAssertTrue(partials.contains("副字幕立即接管"),
                      "a primary error must hand the HUD to the secondary immediately")
    }

    func testHUD_singleEngine_noFallbackEngine_primaryStillDrivesHUD() async {
        // One-engine session: hudFallbackEngine is nil. The primary must still
        // drive the HUD and nothing should crash on the absent fallback.
        let doubao = MockBackend(text: "你好", partialOnStart: "单引擎字幕")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao)],
                                       primary: .doubao, router: router,
                                       hudFallbackSeconds: 0)
        let partials = await hudPartials(multi)
        XCTAssertTrue(partials.contains("单引擎字幕"),
                      "the sole engine must drive the HUD even with no fallback engine")
    }

    func testCancel_cancelsAllEngines() async {
        let doubao = MockBackend(text: "a")
        let soniox = MockBackend(text: "b")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router)
        _ = multi.start()
        multi.cancel()
        await eventually({ doubao.cancelCalled && soniox.cancelCalled })
    }
}
