import Foundation
import Testing
@testable import Providers
import SwiftMCP

private let bookJSONPrompt = """
Please transform the following book information into JSON format:
Title: The Adventures of Tom Sawyer
Author: Mark Twain
Summary: The novel is about a young boy growing up along the Mississippi River and his various adventures.

The JSON schema should be:
{
 "title": "string",
 "author": "string",
 "summary": "string"
}
"""

@MCPServer
private class ChatTestTools {
	@MCPTool(description: "Echoes provided text")
	func say(_ text: String) -> String {
		text
	}
}

struct ChatTests {
	@Test("Chat completion returns multiple choices", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
	func chatCompletion() async throws {
		let openAI = try TestClients.openAI()
		let systemPrompt = ChatMessage(role: .system, content: .text("You are a helpful and witty assistant"))
		let userMessage = ChatMessage(role: .user, content: .text("Tell me a joke"), name: "Xcode")

		let completion = try await openAI.createChatCompletion(
			model: "gpt-4.1-mini",
			messages: [systemPrompt, userMessage],
			n: 3
		)

		#expect(completion.choices.count == 3)
		let answer = try #require(completion.choices.first)
		let content = try #require(answer.message.textContent)
		#expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
		#expect(answer.finishReason == .stop)
	}

	@Test("Chat streaming assembles choices", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
	func chatStreaming() async throws {
		let openAI = try TestClients.openAI()
		let systemPrompt = ChatMessage(role: .system, content: .text("You are a helpful and witty assistant"))
		let userMessage = ChatMessage(role: .user, content: .text("Tell me a joke"), name: "Xcode")

		let stream = try await openAI.createChatCompletionStream(
			model: "gpt-4.1-mini",
			messages: [systemPrompt, userMessage],
			n: 3,
			streamOptions: .includeUsage(true)
		)

		let assembler = ChatCompletionAssembler()
		for try await chunk in stream {
			assembler.processChunk(chunk)
		}

		#expect(assembler.choices.count == 3)
		let content = try #require(assembler.choices.first?.message.textContent)
		let finishReason = try #require(assembler.choices.first?.finishReason)
		#expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
		#expect(finishReason == .stop)

		let usage = try #require(assembler.usage)
		#expect(usage.totalTokens > 0)
	}

	@Test("Chat JSON output", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
	func chatJSONResponse() async throws {
		let openAI = try TestClients.openAI()
		let systemPrompt = ChatMessage(role: .system, content: .text("You are a helpful and witty assistant"))
		let userMessage = ChatMessage(role: .user, content: .text(bookJSONPrompt))

		let completion = try await openAI.createChatCompletion(
			model: "gpt-4.1-mini",
			messages: [systemPrompt, userMessage],
			responseFormat: .json
		)

		let answer = try #require(completion.choices.first)
		let content = try #require(answer.message.textContent)
		let data = Data(content.utf8)
		let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

		#expect(json["title"] as? String == "The Adventures of Tom Sawyer")
		#expect(json["author"] as? String == "Mark Twain")
		#expect(json["summary"] as? String == "The novel is about a young boy growing up along the Mississippi River and his various adventures.")
	}

	@Test("Chat function calling", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
	func chatFunctionCalls() async throws {
		let openAI = try TestClients.openAI()
		let tools: [MCPToolProviding] = [ChatTestTools()]
		let toolDescriptions = tools.flatMap { $0.toolDescriptions }

		let systemPrompt = ChatMessage(role: .system, content: .text("You are a helpful and witty assistant"))
		let userMessage = ChatMessage(role: .user, content: .text("Tell me a joke by calling the `say` function"), name: "Xcode")

		let completion = try await openAI.createChatCompletion(
			model: "gpt-4.1-mini",
			messages: [systemPrompt, userMessage],
			tools: toolDescriptions,
			n: 2
		)

		let finishReason = try #require(completion.choices.first?.finishReason)
		#expect(finishReason == .toolCalls)

		let toolCalls = completion.choices.flatMap { $0.message.toolCalls ?? [] }
		#expect(toolCalls.count == 2)

		let outputs = await tools.perform(toolCalls)
		#expect(outputs.count == 2)
		#expect(outputs.allSatisfy { !$0.output.isEmpty })
	}
}
