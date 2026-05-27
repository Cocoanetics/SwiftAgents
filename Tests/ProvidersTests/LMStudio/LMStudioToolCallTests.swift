//
//  LMStudioToolCallTests.swift
//  ProvidersTests
//
//  Live tool-calling tests against LM Studio:
//   1. Direct `createChatCompletion(tools:)` — confirms the wire path on
//      `/v1/chat/completions` parses tool_calls correctly.
//   2. Runner + `@MCPServer`-decorated tool class — exercises the
//      end-to-end loop, including the policy-driven fallback from LM
//      Studio's native `/api/v1/chat` (which rejects the `tools` field)
//      onto chat completions.
//
//  Tools are defined via SwiftMCP's `@MCPServer` / `@MCPTool` macros, the
//  same way Anthropic / OpenAI Runner tests do it.
//

import Foundation
@testable import Agents
@testable import Providers
import SwiftMCP
import Testing

@MCPServer
private class LMStudioWeatherTools {
    @MCPTool(description: "Returns the current weather for a city")
    func get_weather(city: String) -> String {
        "It is 18°C and partly cloudy in \(city)."
    }
}

private let lmStudioToolModel = ProcessInfo.processInfo.environment["LMSTUDIO_MODEL"]
    ?? "google/gemma-4-26b-a4b"

struct LMStudioToolCallTests {
    @Test(
        "createChatCompletion(tools:) returns a tool_call from LM Studio",
        .enabled(if: TestClients.hasLMStudio, "Requires LMSTUDIO_URL")
    )
    func directChatCompletionToolCall() async throws {
        let client = try TestClients.lmStudio()
        // SwiftMCP synthesises `toolDescriptions` from the `@MCPTool` macros
        // — same code path the Agents Runner uses.
        let toolDescriptions: [ToolDescription] = LMStudioWeatherTools().toolDescriptions

        let completion = try await client.createChatCompletion(
            model: lmStudioToolModel,
            messages: [
                .init(role: .system, content: .text(
                    "You MUST call get_weather for any weather question."
                )),
                .init(role: .user, content: .text("What's the weather in Berlin?"))
            ],
            tools: toolDescriptions,
            temperature: 0
        )

        let firstChoice = try #require(completion.choices.first, "expected at least one choice")
        let toolCalls = try #require(firstChoice.message.toolCalls, "expected tool_calls on first choice")
        #expect(toolCalls.count == 1)
        let firstCall = try #require(toolCalls.first)
        #expect(firstCall.function?.name == "get_weather")
        let arguments = firstCall.function?.arguments ?? ""
        #expect(arguments.lowercased().contains("berlin"))
    }

    @Test(
        "Runner end-to-end: tool call + execution + final response via LM Studio",
        .enabled(if: TestClients.hasLMStudio, "Requires LMSTUDIO_URL")
    )
    func runnerToolCallEndToEnd() async throws {
        let agent = BasicAgent(
            name: "LMStudioWeatherAgent",
            model: "lmstudio/\(lmStudioToolModel)",
            instructions: """
                You MUST call the get_weather tool when asked about weather, \
                then report the result back to the user in plain English.
                """,
            toolProvider: [LMStudioWeatherTools()],
            modelSettings: ModelSettings(temperature: 0)
        )

        let result = try await Runner.run(
            agent: agent,
            input: "What's the weather in Berlin?",
            maxTurns: 5
        )

        let lower = result.finalOutput.lowercased()
        #expect(lower.contains("berlin") || lower.contains("18") || lower.contains("cloudy"))
    }
}
