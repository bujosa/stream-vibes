import Foundation
import XCTest
@testable import ModelConfiguration

final class AIModelTests: XCTestCase {
    func testLegacyModelMigratesOnlyToOwningProvider() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("anthropic_api", forKey: "aiProvider")
        defaults.set("custom-pinned-model", forKey: "aiModel")
        XCTAssertEqual(AIModelPreferences.value(for: "openai_api", defaults: defaults), "")
        XCTAssertEqual(AIModelPreferences.value(for: "anthropic_api", defaults: defaults), "custom-pinned-model")
        XCTAssertNil(defaults.string(forKey: "aiModel"))
        defaults.set("other-model", forKey: AIModelPreferences.key(for: "openai_api"))
        XCTAssertEqual(AIModelPreferences.value(for: "anthropic_api", defaults: defaults), "custom-pinned-model")
    }

    func testOpenAIUsesSelectedModelWithoutUnsupportedSamplingOrLegacyTokenLimit() throws {
        let request = try AIAPITransport.request(provider: .openaiAPI, apiKey: "example", model: "gpt-6.1-sol", prompt: "Example")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-6.1-sol")
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["max_tokens"])
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 8192)
    }

    func testGeminiKeepsKeyOutOfURLAndRejectsInjectedPath() throws {
        let request = try AIAPITransport.request(provider: .geminiAPI, apiKey: "example", model: "gemini-3.8-flash", prompt: "Example")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "example")
        XCTAssertThrowsError(try AIAPITransport.request(provider: .geminiAPI, apiKey: "example", model: "bad/model?key=value", prompt: "Example"))
    }

    func testThinkingBlocksAreNotPresentedAsAnswer() throws {
        let anthropic = Data(#"{"content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Answer"},{"type":"text","text":"More"}]}"#.utf8)
        XCTAssertEqual(try AIAPITransport.text(provider: .anthropicAPI, data: anthropic), "Answer\nMore")
        let gemini = Data(#"{"candidates":[{"content":{"parts":[{"thought":true,"text":"private"},{"text":"Answer"}]}}]}"#.utf8)
        XCTAssertEqual(try AIAPITransport.text(provider: .geminiAPI, data: gemini), "Answer")
    }
}
