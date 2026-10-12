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

    func testRequestUsesCustomPromptAsTheOnlySystemMessage() throws {
        let prompt = "  清理重复、修复断句，保留 agency 等术语。\n只输出正文。\n"
        let refiner = TextRefiner(baseURL: "https://example.test/v1", apiKey: "k",
                                  model: "m", systemPrompt: prompt)
        // Dictation and the settings connection probe share the request builder.
        for (input, timeout) in [("这个、这个 agency。", 20.0), ("ping", 15.0)] {
            let request = try XCTUnwrap(refiner.makeRequest(for: input, timeout: timeout))
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
            XCTAssertEqual(messages, [
                ["role": "system", "content": prompt],
                ["role": "user", "content": input]
            ])
            XCTAssertEqual(request.timeoutInterval, timeout)
        }
    }

    func testRequestFallsBackToDefaultForMissingOrBlankPrompt() throws {
        let refiners = [
            TextRefiner(baseURL: "https://example.test/v1", apiKey: "k", model: "m"),
            TextRefiner(baseURL: "https://example.test/v1", apiKey: "k", model: "m",
                        systemPrompt: " \n\t ")
        ]
        for refiner in refiners {
            let request = try XCTUnwrap(refiner.makeRequest(for: "你好", timeout: 20))
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
            XCTAssertEqual(messages.first?["content"], TextRefiner.defaultSystemPrompt)
        }
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
