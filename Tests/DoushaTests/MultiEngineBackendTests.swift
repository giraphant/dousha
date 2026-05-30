import XCTest
import ASRSupport
@testable import Dousha

final class MultiEngineBackendTests: XCTestCase {

    /// Canned-result SpeechBackend for testing the composite without audio/network.
    private final class MockBackend: SpeechBackend, @unchecked Sendable {
        let result: TranscriptionResult
        let errorOnStart: Error?
        let stopDelay: TimeInterval
        private(set) var startCalled = false
        private(set) var cancelCalled = false

        init(text: String, errorOnStart: Error? = nil, stopDelay: TimeInterval = 0) {
            self.result = TranscriptionResult(text: text, audioDuration: 1,
                                              lastResponseAge: nil, lastTranscriptAge: nil,
                                              savedAudioURL: nil)
            self.errorOnStart = errorOnStart
            self.stopDelay = stopDelay
        }
        func setLanguage(_ identifier: String) {}
        func start(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                   onAudioLevel: @escaping @Sendable (Float) -> Void,
                   onError: @escaping @Sendable (Error) -> Void) {
            startCalled = true
            if let e = errorOnStart { onError(e) }
        }
        func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
            if stopDelay > 0 {
                let r = result
                DispatchQueue.global().asyncAfter(deadline: .now() + stopDelay) { completion(r) }
            } else {
                completion(result)
            }
        }
        func cancel() { cancelCalled = true }
    }

    private final class ErrorBox: @unchecked Sendable { var error: Error? }

    private let router = LanguageRouter(chineseEngine: .doubao,
                                        englishEngine: .soniox,
                                        mixedEngine: .soniox)

    func testStop_routesChineseDominantToDoubao() {
        // Chinese speech: Soniox (the faithful classifier) also renders Han, so it
        // reads as Chinese → route to 豆包's cleaner Chinese transcript.
        let multi = MultiEngineBackend(
            entries: [(.doubao, MockBackend(text: "你好世界你好啊")), (.soniox, MockBackend(text: "你好世界"))],
            primary: .doubao, router: router)
        let exp = expectation(description: "stop")
        multi.stop { XCTAssertEqual($0.text, "你好世界你好啊"); exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    func testStop_englishMangledByDoubao_stillRoutesToSoniox() {
        // User spoke English; 豆包 homophone-mangles to Han (looks Chinese), Soniox
        // shows real English. Classifying on Soniox routes correctly to Soniox.
        let multi = MultiEngineBackend(
            entries: [(.doubao, MockBackend(text: "普莱斯泰勒")), (.soniox, MockBackend(text: "price tailor please"))],
            primary: .doubao, router: router)
        let exp = expectation(description: "stop")
        multi.stop { XCTAssertEqual($0.text, "price tailor please"); exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    func testStop_routesEnglishDominantToSoniox() {
        let multi = MultiEngineBackend(
            entries: [(.doubao, MockBackend(text: "皮森哈喽")), (.soniox, MockBackend(text: "Python hello there"))],
            primary: .soniox, router: router)
        let exp = expectation(description: "stop")
        multi.stop { XCTAssertEqual($0.text, "Python hello there"); exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    func testStop_chosenEngineEmpty_fallsThroughToNonEmpty() {
        // Chinese-dominant score → chosen doubao, but doubao empty → fall through.
        let multi = MultiEngineBackend(
            entries: [(.doubao, MockBackend(text: "")), (.soniox, MockBackend(text: "你好世界你好啊"))],
            primary: .soniox, router: router)
        let exp = expectation(description: "stop")
        multi.stop { XCTAssertEqual($0.text, "你好世界你好啊"); exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    func testStop_allEmpty_returnsEmpty() {
        let multi = MultiEngineBackend(
            entries: [(.doubao, MockBackend(text: "")), (.soniox, MockBackend(text: ""))],
            primary: .doubao, router: router)
        let exp = expectation(description: "stop")
        multi.stop { XCTAssertTrue($0.text.isEmpty); exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    func testStart_secondaryErrorIsNonFatal() {
        let soniox = MockBackend(text: "x", errorOnStart: NSError(domain: "t", code: 1))
        let doubao = MockBackend(text: "你好")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router)
        let box = ErrorBox()
        multi.start(onPartial: { _ in }, onAudioLevel: { _ in }, onError: { box.error = $0 })
        XCTAssertNil(box.error, "a secondary engine's error must not abort the recording")
        XCTAssertTrue(doubao.startCalled)
        XCTAssertTrue(soniox.startCalled)
    }

    func testStart_primaryErrorIsFatal() {
        let doubao = MockBackend(text: "", errorOnStart: NSError(domain: "t", code: 2))
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, MockBackend(text: "ok"))],
                                       primary: .doubao, router: router)
        let box = ErrorBox()
        multi.start(onPartial: { _ in }, onAudioLevel: { _ in }, onError: { box.error = $0 })
        XCTAssertNotNil(box.error, "the primary engine's error must be forwarded as fatal")
    }

    func testStop_englishEarlyExit_doesNotWaitForSlowChineseEngine() {
        // 豆包 is slow (1s); Soniox (classifier) returns English instantly. The
        // result must come back via Soniox WITHOUT waiting the full second.
        let doubao = MockBackend(text: "普莱斯", stopDelay: 1.0)
        let soniox = MockBackend(text: "price please now")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router)
        let exp = expectation(description: "stop")
        let t0 = Date()
        multi.stop { result in
            let elapsed = Date().timeIntervalSince(t0)
            XCTAssertEqual(result.text, "price please now")
            XCTAssertLessThan(elapsed, 0.5, "English should early-exit via Soniox, not wait for the 1s 豆包")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
    }

    func testStop_chineseWaitsForChineseEngine_evenIfSlow() {
        // Soniox (classifier) returns Chinese (Han) instantly → route to 豆包, which
        // is slow (0.4s). Must WAIT for 豆包 and return its cleaner transcript.
        let doubao = MockBackend(text: "今天天气很好啊", stopDelay: 0.4)
        let soniox = MockBackend(text: "今天天气很好")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router)
        let exp = expectation(description: "stop")
        let t0 = Date()
        multi.stop { result in
            let elapsed = Date().timeIntervalSince(t0)
            XCTAssertEqual(result.text, "今天天气很好啊")
            XCTAssertGreaterThan(elapsed, 0.3, "Chinese must wait for 豆包")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
    }

    func testCancel_cancelsAllEngines() {
        let doubao = MockBackend(text: "a")
        let soniox = MockBackend(text: "b")
        let multi = MultiEngineBackend(entries: [(.doubao, doubao), (.soniox, soniox)],
                                       primary: .doubao, router: router)
        multi.cancel()
        XCTAssertTrue(doubao.cancelCalled)
        XCTAssertTrue(soniox.cancelCalled)
    }
}
