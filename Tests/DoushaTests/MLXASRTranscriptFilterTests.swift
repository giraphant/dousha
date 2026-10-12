import XCTest
import ASRSupport
import MLXAudioSTT
@testable import MLXASR

final class MLXASRTranscriptFilterTests: XCTestCase {
    func testCompleteHeadersAtStartAndAcrossWindows() {
        for suppress in [false, true] {
            for name in ["Chinese", "English", "Cantonese", "Japanese", "Middle English"] {
                XCTAssertEqual(visible("language \(name)<asr_text>hello", auto: suppress), "hello")
            }
            XCTAssertEqual(visible("language Chinese<asr_text>你好。 language Chinese<asr_text>世界。", auto: suppress),
                           "你好。世界。")
            XCTAssertEqual(visible("language English<asr_text>Hello language English<asr_text>world", auto: suppress),
                           "Hello world")
        }
    }

    func testRemovalOnlyNormalizesWhitespaceAtRemovedBoundaries() {
        XCTAssertEqual(visible("  language Chinese<asr_text>  你好  "), "你好")
        XCTAssertEqual(visible("Hello \n  language English<asr_text> \t world"), "Hello world")
        XCTAssertEqual(visible("你好 language Chinese<asr_text> 世界"), "你好世界")
        XCTAssertEqual(visible("안녕 language Korean<asr_text> 세상"), "안녕 세상")
        XCTAssertEqual(visible("Hello  world"), "Hello  world")
        XCTAssertEqual(visible("Hello language English<asr_text> language English<asr_text> world"), "Hello world")
    }

    func testEveryIncompleteHeaderCutIsHiddenOnlyInAutoMode() {
        let header = "language Chinese<asr_text>"
        for length in 1..<header.count {
            let tail = String(header.prefix(length))
            XCTAssertEqual(visible(tail), "", "cut=\(tail)")
            XCTAssertEqual(visible("Hello \(tail)"), "Hello", "cut=\(tail)")
            XCTAssertEqual(visible(tail, auto: false), tail.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertEqual(visible("Hello \(tail)", auto: false), "Hello \(tail)".trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for tail in ["language", "language ", "language Chi", "language Chinese<asr_", "language English<"] {
            XCTAssertEqual(visible("language Chinese<asr_text>你好 \(tail)"), "你好")
        }
    }

    func testOrdinaryLanguageTextAndMalformedHeadersSurvive() {
        let ordinary = [
            "language model", "a language model", "language is useful", "language: Chinese",
            "language Chinese people speak", "language C++", "language 123", "lantern",
            "metalanguage Chinese<asr_text>", "你好language Chinese<asr_text>",
            "language Chinese<not_asr>", "language Chinese<asr_textX>",
            "language 中文<asr_text>", "language en-US<asr_text>",
            "language \(String(repeating: "A", count: 33))<asr_text>",
        ]
        for text in ordinary {
            for suppress in [true, false] {
                XCTAssertEqual(visible(text, auto: suppress), text)
            }
        }
        XCTAssertEqual(visible("a language model language Chinese<asr_text>你好"), "a language model 你好")
    }

    func testEmptyAndWhitespaceOnlyText() {
        for text in ["", " ", "\n\t  ", "language Chinese<asr_text>  "] {
            for suppress in [true, false] {
                XCTAssertEqual(visible(text, auto: suppress), "")
            }
        }
    }

    func testHeaderMayStraddleAnyConfirmedProvisionalSplit() {
        let text = "language Chinese<asr_text>你好。 language English<asr_text>Hello world"
        for suppress in [true, false] {
            for offset in 0...text.count {
                let partial = QwenTranscriptFilter.partial(
                    confirmed: String(text.prefix(offset)), provisional: String(text.dropFirst(offset)),
                    suppressIncompleteTail: suppress)
                XCTAssertEqual(partial.combined, "你好。Hello world", "split=\(offset)")
                XCTAssertTrue(partial.combined.hasPrefix(partial.finalText))
                XCTAssertFalse(partial.finalText.contains("language"))
                XCTAssertFalse(partial.finalText.contains("<asr_"))
            }
        }
    }

    func testConfirmedPrefixDoesNotRetractAsHeadersArriveAndConfirm() {
        let text = "language English<asr_text>Hello language English<asr_text>world"
        for suppress in [true, false] {
            var previous = ""
            var state = MLXTranscriptState(suppressIncompleteHeaders: suppress)
            for offset in 0...text.count {
                let confirmed = String(text.prefix(offset))
                let partial = state.consume(.displayUpdate(confirmedText: confirmed, provisionalText: ""))!
                XCTAssertTrue(partial.finalText.hasPrefix(previous), "cut=\(offset), auto=\(suppress)")
                previous = partial.finalText
            }
            XCTAssertEqual(previous, "Hello world")
            XCTAssertEqual(state.finalText(endedText: nil), "Hello world")
        }
    }

    func testExplicitModeKeepsIncompleteHeadersVisibleButUnconfirmed() {
        let partial = QwenTranscriptFilter.partial(confirmed: "Hello language Chi", provisional: "",
                                                  suppressIncompleteTail: false)
        XCTAssertEqual(partial, PartialTranscript(finalText: "Hello", interimText: " language Chi"))
    }

    func testAmbiguousConfirmedTailRestoresOrdinarySpeechInProvisionalText() {
        let partial = QwenTranscriptFilter.partial(confirmed: "a language", provisional: " model",
                                                  suppressIncompleteTail: true)
        XCTAssertEqual(partial, PartialTranscript(finalText: "a", interimText: " language model"))
    }

    func testStateFiltersEndedAndTimeoutFallbackWithSessionMode() {
        for suppress in [true, false] {
            var state = MLXTranscriptState(suppressIncompleteHeaders: suppress)
            _ = state.consume(.displayUpdate(confirmedText: "language Chinese<asr_text>你好 ",
                                             provisionalText: "language Chi"))
            let expected = suppress ? "你好" : "你好 language Chi"
            XCTAssertEqual(state.finalText(endedText: nil), expected)
            XCTAssertEqual(state.finalText(endedText: "language Chinese<asr_text>你好 language Chi"), expected)
            XCTAssertEqual(state.finalText(endedText: "language Chinese<asr_text>你好 language English<asr_text>world"),
                           "你好 world")
            XCTAssertEqual(state.finalText(endedText: ""), "")
        }
    }

    private func visible(_ text: String, auto: Bool = true) -> String {
        QwenTranscriptFilter.visibleText(text, suppressIncompleteTail: auto)
    }
}
