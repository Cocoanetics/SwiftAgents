import Foundation
import Testing
@testable import AgentCorp

struct GoogleThinkingConfigTests {
	@Test("Encodes thinking config into generation config payload")
	func encodesThinkingConfig() throws {
		let thinkingConfig = GoogleThinkingConfig(includeThoughts: true, thinkingLevel: .high, thinkingBudget: 2048)
		let request = GoogleGenerateContentRequest(
			contents: [.init(role: "user", parts: [.text("Hello!")])],
			systemInstruction: nil,
			tools: nil,
			generationConfig: .init(thinkingConfig: .init(from: thinkingConfig), imageConfig: nil)
		)

		let api = GoogleAPI()
		let data = try api.encoder.encode(request)
		let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		let generationConfig = try #require(root["generation_config"] as? [String: Any], "generation_config missing")
		let thinking = try #require(generationConfig["thinking_config"] as? [String: Any], "thinking_config missing")

		#expect(thinking["include_thoughts"] as? Bool == true)
		#expect(thinking["thinking_level"] as? String == "high")
		#expect(thinking["thinking_budget"] as? Int == 2048)
	}

	@Test("Thought parts map to reasoning content")
	func decodesThoughtSummaryIntoReasoningContent() throws {
		let responseJSON = """
		{
		  "candidates": [
			{
			  "content": {
				"role": "model",
				"parts": [
				  { "thought": true, "text": "Break down the question" },
				  { "text": "Here is the answer." }
				]
			  },
			  "finish_reason": "STOP",
			  "index": 0
			}
		  ],
		  "model_version": "gemini-test"
		}
		""".data(using: .utf8)!

		let httpResponse = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
		let api = GoogleAPI()
		let completion = try api.makeChatCompletionResponse(model: "gemini-2.5-pro", data: responseJSON, response: httpResponse)
		let message = try #require(completion.choices.first?.message, "Completion missing expected message")

		#expect(message.reasoningContent == "Break down the question")
		#expect(message.textContent == "Here is the answer.")
	}

	@Test("Gemini 3 Pro Preview with thinking level", .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY"))
	func liveGemini3ProPreviewThinkingLevel() async throws {
		let google = GoogleAPI(apiKey: APIKey.gemini!)
		let prompt = "List two Austrian cities and one fun fact about each."
		let thinking = GoogleThinkingConfig(includeThoughts: true, thinkingLevel: .high, thinkingBudget: nil)
		let response = try await google.createChatCompletion(
			model: "gemini-3-pro-preview",
			messages: [.init(role: .user, content: .text(prompt))],
			thinkingConfig: thinking
		)

		let message = try #require(response.choices.first?.message, "Response contained no choices")
		let text = try #require(nonEmptyText(from: message), "Expected textual content from model")
		#expect(!text.isEmpty)
		#expect(message.reasoningContent?.isEmpty == false, "Expected thought summary when includeThoughts is true")
	}

	@Test("Gemini Flash thinking budget", .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY"))
	func liveGeminiFlashThinkingBudget() async throws {
		let google = GoogleAPI(apiKey: APIKey.gemini!)
		let prompt = "Give a two-step plan to brew a cup of tea."
		let thinking = GoogleThinkingConfig(includeThoughts: true, thinkingLevel: nil, thinkingBudget: 256)
		let response = try await google.createChatCompletion(
			model: "gemini-flash-latest",
			messages: [.init(role: .user, content: .text(prompt))],
			thinkingConfig: thinking
		)

		let message = try #require(response.choices.first?.message, "Response contained no choices")
		let text = try #require(nonEmptyText(from: message), "Expected textual content from model")
		#expect(!text.isEmpty)
		#expect(message.reasoningContent?.isEmpty == false, "Expected thought summary when includeThoughts is true")
	}

	// MARK: - Helpers

	private func nonEmptyText(from message: ChatMessage) -> String? {
		if let text = message.textContent?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
			return text
		}
		if let parts = message.contentParts {
			let joined = ChatMessage.ContentPart.joinedText(from: parts)?.trimmingCharacters(in: .whitespacesAndNewlines)
			if let joined, !joined.isEmpty {
				return joined
			}
		}
		return nil
	}
}
