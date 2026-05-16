import Foundation
@testable import Providers
import SwiftMCP
import Testing

@MCPServer
private class OllamaTools {
    @MCPTool(description: "Echoes provided text")
    func say(_ text: String) -> String {
        text
    }
}

struct OllamaChatTests {
    private static let runOllamaTests = ProcessInfo.processInfo.environment["RUN_OLLAMA_TESTS"] != nil
    @Test(
        "Ollama chat completion",
        .enabled(if: Self.runOllamaTests && TestClients.hasOllama, "Requires OLLAMA_URL and RUN_OLLAMA_TESTS=1")
    )
    func chatCompletion() async throws {
        let ollama = try TestClients.ollama()
        let systemPrompt = ChatMessage(role: .system, content: .text("You are a helpful and witty assistant"))
        let userMessage = ChatMessage(role: .user, content: .text("Tell me a joke"), name: "Xcode")

        let completion = try await ollama.createChatCompletion(
            model: "llama3",
            messages: [systemPrompt, userMessage],
            n: 1
        )

        #expect(completion.choices.count == 1)
        let answer = try #require(completion.choices.first)
        let content = try #require(answer.message.textContent)
        #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(answer.finishReason == .stop)
    }

    @Test(
        "Ollama chat streaming",
        .enabled(if: Self.runOllamaTests && TestClients.hasOllama, "Requires OLLAMA_URL and RUN_OLLAMA_TESTS=1")
    )
    func chatStreaming() async throws {
        let ollama = try TestClients.ollama()
        let systemPrompt = ChatMessage(role: .system, content: .text("You are a helpful and witty assistant"))
        let userMessage = ChatMessage(role: .user, content: .text("Tell me a joke"), name: "Xcode")

        let stream = try await ollama.createChatCompletionStream(
            model: "llama3",
            messages: [systemPrompt, userMessage],
            n: 1
        )
        let assembler = ChatCompletionAssembler()
        for try await chunk in stream {
            assembler.processChunk(chunk)
        }

        #expect(assembler.choices.count == 1)
        let text = try #require(assembler.choices.first?.message.textContent)
        let finishReason = try #require(assembler.choices.first?.finishReason)
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(finishReason == .stop)
    }

    @Test(
        "Ollama function calling",
        .enabled(if: Self.runOllamaTests && TestClients.hasOllama, "Requires OLLAMA_URL and RUN_OLLAMA_TESTS=1")
    )
    func chatFunctionCalling() async throws {
        let ollama = try TestClients.ollama()
        let tools: [MCPToolProviding] = [OllamaTools()]
        let toolDescriptions = tools.flatMap(\.toolDescriptions)

        let systemPrompt = ChatMessage(role: .system, content: .text("You are a helpful and witty assistant"))
        let userMessage = ChatMessage(
            role: .user,
            content: .text("Tell me a joke by calling the `say` function"),
            name: "Xcode"
        )

        let completion = try await ollama.createChatCompletion(
            model: "llama3",
            messages: [systemPrompt, userMessage],
            tools: toolDescriptions
        )

        let finishReason = try #require(completion.choices.first?.finishReason)
        #expect(finishReason == .toolCalls)
        let toolCalls = completion.choices.flatMap { $0.message.toolCalls ?? [] }
        #expect(toolCalls.count == 1)

        let outputs = await tools.perform(toolCalls)
        #expect(outputs.count == 1)
        #expect(outputs.allSatisfy { !$0.output.isEmpty })
    }
}
