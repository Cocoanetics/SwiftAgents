//
//  AnthropicResponsesTests.swift
//  ProvidersTests
//
//  Integration tests for the Responses API surface on Anthropic, including
//  end-to-end exercises through the Agents SDK Runner.
//

import Foundation
@testable import Providers
import SwiftMCP
import Testing

@MCPServer
private class AnthropicResponsesTools {
    @MCPTool(description: "Returns the current weather for a city")
    func get_weather(city: String) -> String {
        "It is 18°C and partly cloudy in \(city)."
    }
}

struct AnthropicResponsesTests {
    private let model = "claude-haiku-4-5"

    @Test("Responses API non-streaming via Anthropic", .enabled(if: APIKey.hasAnthropic, "Requires ANTHROPIC_API_KEY"))
    func responsesAPI() async throws {
        let client = try TestClients.anthropic()
        let response = try await client.createResponse(
            input: .text("Say hello in one short sentence."),
            model: model,
            instructions: "You are a concise assistant.",
            maxOutputTokens: 200
        )

        #expect(response.status == .completed)
        let text = textFromResponse(response)
        #expect(!text.isEmpty)
        #expect(response.usage?.inputTokens ?? 0 > 0)
    }

    @Test("Responses API streaming via Anthropic", .enabled(if: APIKey.hasAnthropic, "Requires ANTHROPIC_API_KEY"))
    func responsesStreaming() async throws {
        let client = try TestClients.anthropic()
        let stream = try await client.createResponseStream(
            input: .text("Count to three."),
            model: model,
            instructions: "You are a concise assistant.",
            maxOutputTokens: 200
        )

        var sawCreated = false
        var sawCompleted = false
        var accumulatedDelta = ""
        var completedResponse: Response?

        for try await event in stream {
            switch event.object {
                case .responseCreated:
                    sawCreated = true
                case let .outputTextDelta(info):
                    accumulatedDelta += info.delta
                case let .responseCompleted(response):
                    sawCompleted = true
                    completedResponse = response
                default:
                    continue
            }
        }

        #expect(sawCreated)
        #expect(sawCompleted)
        #expect(!accumulatedDelta.isEmpty)
        let final = try #require(completedResponse)
        #expect(final.status == .completed)
    }

    @Test("Agents SDK Runner end-to-end via anthropic/claude-*",
          .enabled(if: APIKey.hasAnthropic, "Requires ANTHROPIC_API_KEY"))
    func agentRunnerEndToEnd() async throws {
        try await registerAnthropicForTests()

        let agent = BasicAgent(
            name: "AnthropicGreeter",
            model: "anthropic/\(model)",
            instructions: "Reply with exactly the word HELLO in uppercase, nothing else.",
            modelSettings: ModelSettings(temperature: 0)
        )

        let result = try await Runner.run(agent: agent, input: "say hello", maxTurns: 3)
        #expect(result.finalOutput.uppercased().contains("HELLO"))
    }

    @Test("Agents SDK Runner with tool calls via Anthropic",
          .enabled(if: APIKey.hasAnthropic, "Requires ANTHROPIC_API_KEY"))
    func agentRunnerWithTools() async throws {
        try await registerAnthropicForTests()

        let agent = BasicAgent(
            name: "AnthropicWeather",
            model: "anthropic/\(model)",
            instructions: """
                When asked about weather, you MUST call the get_weather tool. \
                Report the result back to the user.
                """,
            toolProvider: [AnthropicResponsesTools()],
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

    @Test(
        "Traces from an Anthropic Runner can be ingested by the OpenAI traces backend",
        .enabled(if: APIKey.hasAnthropic && APIKey.hasOpenAI,
                 "Requires ANTHROPIC_API_KEY and OPENAI_API_KEY")
    )
    func tracesShipToOpenAI() async throws {
        try await registerAnthropicForTests()

        // Capture every span the global tracer emits during the agent run.
        actor Spy: TracingExporter {
            var captured: [[String: JSONValue]] = []
            nonisolated func export(_ items: [[String: JSONValue]]) async {
                await append(items)
            }
            func append(_ items: [[String: JSONValue]]) { captured.append(contentsOf: items) }
            func snapshot() -> [[String: JSONValue]] { captured }
        }
        let spy = Spy()
        await TraceProvider.shared.setProcessors([
            BatchTraceProcessor(exporter: spy, scheduleDelay: 0.1)
        ])

        // Drive an agent so spans are generated.
        let agent = BasicAgent(
            name: "AnthropicTraceProbe",
            model: "anthropic/\(model)",
            instructions: "Reply with exactly the word OK.",
            modelSettings: ModelSettings(temperature: 0)
        )
        _ = try await Runner.run(agent: agent, input: "go", maxTurns: 3)

        // Wait for the batch processor to flush (scheduleDelay = 100ms).
        try await Task.sleep(for: .milliseconds(500))

        let captured = await spy.snapshot()
        #expect(!captured.isEmpty, "Expected the Runner to emit at least one trace/span")

        // Round-trip the captured spans through OpenAI's trace ingestion
        // endpoint — this is the same call BackendSpanExporter makes.
        let openAIKey = try #require(APIKey.openAI as String?)
        let openAI = OpenAI(apiKey: openAIKey)
        try await openAI.ingestTraces(captured)
    }

    @Test("Runner streaming yields events via Anthropic",
          .enabled(if: APIKey.hasAnthropic, "Requires ANTHROPIC_API_KEY"))
    func runnerStreamingEndToEnd() async throws {
        try await registerAnthropicForTests()

        let agent = BasicAgent(
            name: "AnthropicStreamer",
            model: "anthropic/\(model)",
            instructions: "Write the phrase 'streaming works' in lowercase, nothing else.",
            modelSettings: ModelSettings(temperature: 0)
        )

        let runResult = Runner.runStreamed(agent: agent, input: "go", maxTurns: 3)

        var sawMessage = false
        for try await event in runResult.events {
            if case let .runItemEvent(_, item) = event,
                case let .message(text) = item, !text.isEmpty {
                sawMessage = true
            }
        }
        #expect(sawMessage)
    }

    // MARK: - Helpers

    private func textFromResponse(_ response: Response) -> String {
        let sections: [String] = response.output.compactMap { output in
            guard case let .message(message) = output else { return nil }
            let parts = message.content.compactMap { content -> String? in
                if case let .outputText(outputText) = content { return outputText.text } else { return nil }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return sections.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The shared registry caches a provider keyed by name. The default
    /// instance reads the key from `ANTHROPIC_API_KEY` — which is what we
    /// want here — so this is mostly a sanity check that the registry can
    /// resolve `anthropic/claude-*` model strings before the Runner asks
    /// for one.
    private func registerAnthropicForTests() async throws {
        _ = try await Providers.shared.api(for: "anthropic/\(model)")
    }
}
