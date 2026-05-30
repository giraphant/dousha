import XCTest
@testable import Dousha

final class TextRefinerTests: XCTestCase {
    func testIsConfiguredRequiresAllThreeFields() {
        XCTAssertFalse(TextRefiner(baseURL: "", apiKey: "k", model: "m").isConfigured)
        XCTAssertFalse(TextRefiner(baseURL: "u", apiKey: "", model: "m").isConfigured)
        XCTAssertFalse(TextRefiner(baseURL: "u", apiKey: "k", model: "").isConfigured)
        XCTAssertTrue(TextRefiner(baseURL: "u", apiKey: "k", model: "m").isConfigured)
    }

    func testCleanStripsCodeFences() {
        let raw = "```\nPython is great\n```"
        XCTAssertEqual(TextRefiner.cleanLLMOutput(raw), "Python is great")
    }

    func testCleanStripsSurroundingQuotes() {
        XCTAssertEqual(TextRefiner.cleanLLMOutput("\"hello\""), "hello")
        XCTAssertEqual(TextRefiner.cleanLLMOutput("\u{201C}你好\u{201D}"), "你好")
        XCTAssertEqual(TextRefiner.cleanLLMOutput("「你好」"), "你好")
    }

    func testCleanLeavesPlainTextUntouched() {
        XCTAssertEqual(TextRefiner.cleanLLMOutput("  用 Python 写个 API  "), "用 Python 写个 API")
    }

    func testChatCompletionsURLAppendsPathWhenMissing() {
        XCTAssertEqual(
            TextRefiner.chatCompletionsURL(base: "https://api.openai.com/v1")?.absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
    }

    func testChatCompletionsURLKeepsExistingPath() {
        XCTAssertEqual(
            TextRefiner.chatCompletionsURL(base: "https://x.test/v1/chat/completions")?.absoluteString,
            "https://x.test/v1/chat/completions"
        )
    }

    func testChatCompletionsURLNilOnEmpty() {
        XCTAssertNil(TextRefiner.chatCompletionsURL(base: "   "))
    }
}
