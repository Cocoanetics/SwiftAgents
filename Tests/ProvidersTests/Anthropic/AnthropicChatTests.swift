//
//  AnthropicChatTests.swift
//  ProvidersTests
//
//  Integration tests against api.anthropic.com. Gated on ANTHROPIC_API_KEY.
//

import Foundation
@testable import Providers
import SwiftMCP
import Testing

@MCPServer
private class AnthropicChatTestTools {
    @MCPTool(description: "Echoes the provided text back")
    func say(_ text: String) -> String {
        text
    }

    @MCPTool(description: "Returns a fixed temperature for the given location")
    func get_weather(location: String) -> String {
        "It is 22°C and sunny in \(location)."
    }
}

struct AnthropicChatTests {
    private let model = "claude-haiku-4-5"

    @Test("Anthropic chat completion", .enabled(if: APIKey.hasAnthropic, "Requires ANTHROPIC_API_KEY"))
    func chatCompletion() async throws {
        let client = try TestClients.anthropic()
        let messages: [ChatMessage] = [
            .init(role: .system, content: .text("You are a helpful assistant. Answer in one short sentence.")),
            .init(role: .user, content: .text("Say hi."))
        ]
        let completion = try await client.createChatCompletion(
            model: model,
            messages: messages,
            maxCompletionTokens: 200
        )

        let choice = try #require(completion.choices.first)
        let content = try #require(choice.message.textContent)
        #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(choice.finishReason == .stop)
    }

    @Test("Anthropic function calling", .enabled(if: APIKey.hasAnthropic, "Requires ANTHROPIC_API_KEY"))
    func functionCalling() async throws {
        let client = try TestClients.anthropic()
        let tools: [MCPToolProviding] = [AnthropicChatTestTools()]
        let toolDescriptions = tools.flatMap(\.toolDescriptions)

        let systemPrompt = "You have access to a get_weather tool. Use it when asked about weather."
        let messages: [ChatMessage] = [
            .init(role: .system, content: .text(systemPrompt)),
            .init(role: .user, content: .text("What's the weather in Paris?"))
        ]

        let completion = try await client.createChatCompletion(
            model: model,
            messages: messages,
            tools: toolDescriptions,
            maxCompletionTokens: 1024
        )

        let choice = try #require(completion.choices.first)
        #expect(choice.finishReason == .toolCalls)
        let toolCalls = try #require(choice.message.toolCalls)
        #expect(toolCalls.contains { $0.function?.name == "get_weather" })
    }

    @Test("Anthropic vision", .enabled(if: APIKey.hasAnthropic, "Requires ANTHROPIC_API_KEY"))
    func visionImageUnderstanding() async throws {
        let client = try TestClients.anthropic()
        let url = try #require(
            Bundle.module.url(forResource: "vision-test", withExtension: "png"),
            "vision-test fixture is required"
        )
        let data = try Data(contentsOf: url)
        let textPart = ChatMessage.ContentPart(text: "What is shown in this image? Answer in one short sentence.")
        let imagePart = ChatMessage.ContentPart.imageDataPart(mimeType: "image/png", data: data)
        let messages: [ChatMessage] = [
            .init(role: .user, content: .parts([textPart, imagePart]))
        ]

        let completion = try await client.createChatCompletion(
            model: model,
            messages: messages,
            maxCompletionTokens: 200
        )

        let choice = try #require(completion.choices.first)
        let content = try #require(choice.message.textContent)
        #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
