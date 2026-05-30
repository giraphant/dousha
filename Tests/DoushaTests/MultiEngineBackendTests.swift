import XCTest
import ASRSupport
@testable import Dousha

final class MultiEngineBackendTests: XCTestCase {

    /// Canned-result SpeechBackend for testing the composite without audio/network.
    private final class MockBackend: SpeechBackend, @unchecked Sendable {
        let result: TranscriptionResult
        let errorOnStart: Error?
        private(set) var startCalled = false
        private(set) var cancelCalled = false

        init(text: String, errorOnStart: Error? = nil) {
            self.result = TranscriptionResult(text: text, audioDuration: 1,
                                              lastResponseAge: nil, lastTranscriptAge: nil,
                                              savedAudioURL: nil)
            self.errorOnStart = errorOnStart
        }
        func setLanguage(_ identifier: String) {}
        func start(onPartial: @escaping @Sendable (PartialTranscript) -> Void,
                   onAudioLevel: @escaping @Sendable (Float) -> Void,
                   onError: @escaping @Sendable (Error) -> Void) {
            startCalled = true
            if let e = errorOnStart { onError(e) }
        }
        func stop(completion: @escaping @Sendable (TranscriptionResult) -> Void) {
            completion(result)
        }
        func cancel() { cancelCalled = true }
    }

    private final class ErrorBox: @unchecked Sendable { var error: Error? }

    private let router = LanguageRouter(chineseEngine: .doubao,
                                        englishEngine: .soniox,
                                        mixedEngine: .soniox)

    func testStop_routesChineseDominantToDoubao() {
        let multi = MultiEngineBackend(
            entries: [(.doubao, MockBackend(text: "你好世界你好啊")), (.soniox, MockBackend(text: "ni hao"))],
            primary: .doubao, router: router)
        let exp = expectation(description: "stop")
        multi.stop { XCTAssertEqual($0.text, "你好世界你好啊"); exp.fulfill() }
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
