//
//  GeminiRunnerTests.swift
//  ProvidersTests
//
//  End-to-end coverage via the Agents SDK Runner against Gemini.
//  Mirrors the LM Studio test set: plain chat, tool calls, structured
//  output, multimodal image input, session round-trip across runs, and
//  trace ingestion to platform.openai.com.
//
//  Gemini doesn't implement `ServerHistoryAPI` (no Responses-API
//  equivalent), so every Runner.run for Gemini takes the chat-
//  completion fallback path in Runner.swift. That path passes
//  `responseFormat: agent.responseFormat` through to
//  `GoogleAPI.createChatCompletion`, where Gemini's GenerationConfig
//  picks up the schema — so structured output is server-enforced, not
//  prompt-driven.
//
//  Streaming via Runner is not yet wired for Gemini (see
//  Runner+Streaming.swift) — covered separately when the dispatch
//  lands.
//
//  Gated on GEMINI_API_KEY (and OPENAI_API_KEY for trace-ingestion).
//

import Foundation
@testable import Agents
import Tracing
@testable import Providers
import SwiftMCP
import Testing

private let geminiModel = "gemini-2.5-flash"

// MARK: - Tool-call fixtures

@MCPServer
private final class GeminiRunnerWeatherTools {
    @MCPTool(description: "Returns the current weather for a city")
    func get_weather(city: String) -> String {
        "It is 18°C and partly cloudy in \(city)."
    }
}

// MARK: - Structured-output fixtures

@Schema
private struct GeminiColourGuess: Codable, Equatable {
    let colour: String
    let confidence: Double
}

private final class GeminiColourGuessAgent: Agent {
    typealias OutputType = GeminiColourGuess
    let name = "GeminiColourGuesser"
    let model: String? = "google/\(geminiModel)"
    let instructions = "Decide what colour a thing usually is. Answer concisely."
    let modelSettings = ModelSettings(temperature: 0)
}

// MARK: - Image fixtures

/// 1×1 solid-red PNG. Same payload used by LM Studio and Anthropic
/// vision tests so the "answer red" assertion is portable.
private let solidRedPNG: String =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

struct GeminiRunnerTests {
    // MARK: - Chat end-to-end

    @Test(
        "Runner end-to-end via google/gemini-* completes a turn",
        .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY")
    )
    func runnerEndToEnd() async throws {
        try await registerGoogleForTests()

        let agent = BasicAgent(
            name: "GeminiGreeter",
            model: "google/\(geminiModel)",
            instructions: "Reply with exactly the word HELLO in uppercase, nothing else.",
            modelSettings: ModelSettings(temperature: 0)
        )

        let result = try await Runner.run(agent: agent, input: "say hello", maxTurns: 3)
        #expect(result.finalOutput.uppercased().contains("HELLO"))
    }

    // MARK: - Tool calls

    @Test(
        "Runner end-to-end with tool calls via Gemini",
        .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY")
    )
    func runnerWithTools() async throws {
        try await registerGoogleForTests()

        let agent = BasicAgent(
            name: "GeminiWeather",
            model: "google/\(geminiModel)",
            instructions: """
                When asked about weather, you MUST call the get_weather tool. \
                Report the result back to the user.
                """,
            toolProvider: [GeminiRunnerWeatherTools()],
            modelSettings: ModelSettings(temperature: 0)
        )

        let result = try await Runner.run(
            agent: agent,
            input: "What's the weather in Berlin?",
            maxTurns: 5
        )

        // The model must reference the tool result somewhere — either
        // the city, the temperature, or "cloudy".
        let lower = result.finalOutput.lowercased()
        #expect(lower.contains("berlin") || lower.contains("18") || lower.contains("cloudy"))
    }

    // MARK: - Structured output

    @Test(
        "Runner produces a @Schema-decoded result from Gemini via responseFormat",
        .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY")
    )
    func runnerStructuredOutput() async throws {
        try await registerGoogleForTests()

        let agent = GeminiColourGuessAgent()
        let result = try await Runner.run(
            agent: agent,
            input: "What colour is grass?",
            maxTurns: 3
        )
        // Gemini honors the json_schema response_format → the Runner
        // decodes the strict JSON the model emitted into our @Schema
        // struct. If this ever stops decoding, the schema plumbing
        // through GoogleAPI.createChatCompletion regressed.
        #expect(!result.finalOutput.colour.isEmpty)
        #expect(result.finalOutput.confidence.isFinite)
    }

    // MARK: - Image input

    @Test(
        "Runner.run accepts a multimodal Response.Input against Gemini",
        .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY")
    )
    func runnerMultimodalInput() async throws {
        try await registerGoogleForTests()

        let agent = BasicAgent(
            name: "GeminiVision",
            model: "google/\(geminiModel)",
            instructions: "You are a concise visual assistant. Answer with one word.",
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 200)
        )

        let dataURL = URL(string: "data:image/png;base64,\(solidRedPNG)")!
        let multimodal: Response.Input = .array([
            .message(.init(
                role: .user,
                content: [
                    .inputText("What colour is this image? Answer with one word."),
                    .inputImage(dataURL)
                ]
            ))
        ])

        let result = try await Runner.run(
            agent: agent,
            input: multimodal,
            maxTurns: 2
        )
        #expect(result.finalOutput.lowercased().contains("red"))
    }

    @Test(
        "Session round-trip: Gemini image input persisted then replayed across runs",
        .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY")
    )
    func sessionImageRoundTrip() async throws {
        try await registerGoogleForTests()

        let agent = BasicAgent(
            name: "GeminiVisionMemory",
            model: "google/\(geminiModel)",
            instructions: """
                You are a concise assistant with visual memory. Answer briefly. \
                When asked about an earlier image, recall what colour you saw.
                """,
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 200)
        )

        let session = InMemorySession()
        let dataURL = URL(string: "data:image/png;base64,\(solidRedPNG)")!

        let second = try await withTrace(name: "Gemini vision memory") {
            _ = try await Runner.run(
                agent: agent,
                input: .array([
                    .message(.init(role: .user, content: [
                        .inputText("Look at this image. What colour is it?"),
                        .inputImage(dataURL)
                    ]))
                ]),
                session: session,
                maxTurns: 2
            )

            let afterFirst = await session.getItems(limit: nil)
            #expect(afterFirst.count >= 2)
            let sawImage = afterFirst.contains { element in
                if case let .message(msg) = element, msg.role == .user {
                    return msg.content.contains { part in
                        if case .inputImage = part { return true }
                        return false
                    }
                }
                return false
            }
            #expect(sawImage, "expected the user's image part to be persisted in the session")

            return try await Runner.run(
                agent: agent,
                input: "What colour was the image I just showed you?",
                session: session,
                maxTurns: 2
            )
        }
        #expect(second.finalOutput.lowercased().contains("red"))
    }

    // MARK: - Traces

    @Test(
        "Gemini Runner emits agent + generation spans",
        .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY")
    )
    func tracingForRun() async throws {
        try await registerGoogleForTests()

        actor Spy: TracingExporter {
            var captured: [[String: JSONValue]] = []
            nonisolated func export(_ items: [[String: JSONValue]]) async {
                await append(items)
            }
            func append(_ items: [[String: JSONValue]]) { captured.append(contentsOf: items) }
            func snapshot() -> [[String: JSONValue]] { captured }
        }
        let spy = Spy()
        await TraceProvider.shared.addProcessor(
            BatchTraceProcessor(exporter: spy, scheduleDelay: 0.1)
        )

        let agentName = "GeminiTraceProbe_\(UUID().uuidString)"
        let agent = BasicAgent(
            name: agentName,
            model: "google/\(geminiModel)",
            instructions: "Answer with one word.",
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 50)
        )

        _ = try await Runner.run(agent: agent, input: "Reply OK", maxTurns: 2)
        try await Task.sleep(for: .milliseconds(500))

        let captured = await spy.snapshot()
        #expect(!captured.isEmpty, "expected the Runner to emit at least one trace/span")

        let encoder = JSONEncoder()
        let flattened = captured.compactMap { item -> String? in
            guard let data = try? encoder.encode(item),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return json
        }
        let anchorJSON = flattened.first(where: { $0.contains(agentName) })
        let anchor = try #require(anchorJSON, "no spans for \(agentName)")
        let traceID = Self.extractTraceID(from: anchor)
        let resolvedTraceID = try #require(traceID, "expected a trace_id on the agent span")
        let mine = flattened.filter { $0.contains(resolvedTraceID) }
        let joined = mine.joined(separator: "\n")

        #expect(joined.contains("\"type\":\"agent\""),
                "expected at least one agent span")
        // Gemini routes through chat completions (no createResponse),
        // so per-turn spans carry GenerationSpanData — same shape LM
        // Studio emits.
        #expect(joined.contains("\"type\":\"generation\""),
                "expected at least one generation span")
    }

    @Test(
        "Traces from a Gemini Runner can be ingested by the OpenAI traces backend",
        .enabled(
            if: APIKey.hasGemini && APIKey.hasOpenAI,
            "Requires GEMINI_API_KEY and OPENAI_API_KEY"
        )
    )
    func tracesShipToOpenAI() async throws {
        try await registerGoogleForTests()

        actor Spy: TracingExporter {
            var captured: [[String: JSONValue]] = []
            nonisolated func export(_ items: [[String: JSONValue]]) async {
                await append(items)
            }
            func append(_ items: [[String: JSONValue]]) { captured.append(contentsOf: items) }
            func snapshot() -> [[String: JSONValue]] { captured }
        }
        let spy = Spy()
        await TraceProvider.shared.addProcessor(
            BatchTraceProcessor(exporter: spy, scheduleDelay: 0.1)
        )

        let agentName = "GeminiIngestProbe_\(UUID().uuidString)"
        let agent = BasicAgent(
            name: agentName,
            model: "google/\(geminiModel)",
            instructions: "Answer with one word.",
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 50)
        )

        _ = try await Runner.run(agent: agent, input: "Reply with OK.", maxTurns: 2)
        try await Task.sleep(for: .milliseconds(500))

        let captured = await spy.snapshot()
        let encoder = JSONEncoder()
        let entries = captured.compactMap { entry -> (entry: [String: JSONValue], json: String)? in
            guard let data = try? encoder.encode(entry),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return (entry, json)
        }
        let anchor = try #require(
            entries.first(where: { $0.json.contains(agentName) }),
            "no agent span for \(agentName)"
        )
        guard case let .string(traceID) = anchor.entry["trace_id"] ?? .null else {
            Issue.record("agent span has no trace_id")
            return
        }
        let mine = entries.filter { $0.json.contains(traceID) }.map(\.entry)
        #expect(!mine.isEmpty)

        // OpenAITraceExporter does this on every flush. A 4xx here is
        // exactly why a run would fail to show up on platform.openai.com.
        let openAIKey = try #require(APIKey.openAI as String?)
        let openAI = OpenAI(apiKey: openAIKey)
        try await openAI.ingestTraces(mine)
    }

    // MARK: - Helpers

    /// Make sure the registry resolves the `google/...` model string
    /// before the Runner asks for one. Picks up `GEMINI_API_KEY` from
    /// the environment via the default `GoogleAPI()` initializer.
    private func registerGoogleForTests() async throws {
        _ = try await ProviderRegistry.shared.api(for: "google/\(geminiModel)")
    }

    /// Pulls the `trace_id` out of a flattened span/trace JSON blob.
    private static func extractTraceID(from json: String) -> String? {
        guard let range = json.range(of: "\"trace_id\":\""),
              let end = json[range.upperBound...].firstIndex(of: "\"") else {
            return nil
        }
        return String(json[range.upperBound ..< end])
    }
}
