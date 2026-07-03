//
//  LMStudioStructuredOutputTests.swift
//  ProvidersTests
//
//  Live tests that LM Studio honors json_schema structured output:
//   1. Direct `createChatCompletion(responseFormat:)` against the
//      OpenAI-compat `/v1/chat/completions` — the path LM Studio's docs
//      document support on.
//   2. Via the agents Runner with a `@Schema`-decorated `OutputType` —
//      the runner must detect that `lmStudioNative.supportsStructuredOutput`
//      is false and route through chat completions instead of the native
//      `/api/v1/chat` (which rejects every known schema field).
//
//  Both are gated on `LMSTUDIO_URL`; the second also reads `LMSTUDIO_MODEL`.
//

import Foundation
@testable import Agents
@testable import Providers
import SwiftMCP
import Testing

private let lmStudioModel = ProcessInfo.processInfo.environment["LMSTUDIO_MODEL"]
    ?? "google/gemma-4-26b-a4b"

@Schema
private struct ColourGuess: Codable, Equatable {
    let colour: String
    let confidence: Double
}

private final class ColourGuessAgent: Agent {
    typealias OutputType = ColourGuess
    let name = "ColourGuesser"
    let model: String? = "lmstudio/\(lmStudioModel)"
    let instructions = """
    Decide what colour a thing usually is. Answer concisely.
    """
    let modelSettings = ModelSettings(temperature: 0)
}

struct LMStudioStructuredOutputTests {
    @Test(
        "createChatCompletion(responseFormat: jsonSchema) returns JSON matching the schema",
        LiveGate.lmStudio
    )
    func directChatCompletionWithSchema() async throws {
        let client = try TestClients.lmStudio()

        // Use the schema the `@Schema` macro generated for `ColourGuess`
        // — that's the same shape `Agent.outputType` produces, so the
        // wire-level test matches what the runner-level test exercises.
        let format = ChatCompletionRequest.ResponseFormat.jsonSchema(ColourGuess.jsonSchema)

        let completion = try await client.createChatCompletion(
            model: lmStudioModel,
            messages: [
                .init(role: .system, content: .text("Reply with structured JSON.")),
                .init(role: .user, content: .text("What colour is grass?"))
            ],
            temperature: 0,
            responseFormat: format
        )

        let raw = completion.choices.first?.message.textContent ?? ""
        #expect(!raw.isEmpty, "expected text content")
        let data = Data(raw.utf8)
        let decoded = try JSONDecoder().decode(ColourGuess.self, from: data)
        // Model can return whatever it wants for `confidence`; the schema
        // only constrains type. Just confirm the field was emitted.
        #expect(!decoded.colour.isEmpty)
        #expect(decoded.confidence.isFinite)
    }

    @Test(
        "Runner falls back to chat completions for LM Studio structured-output runs",
        LiveGate.lmStudio
    )
    func runnerStructuredOutput() async throws {
        let agent = ColourGuessAgent()
        let result = try await Runner.run(
            agent: agent,
            input: "What colour is grass?",
            maxTurns: 3
        )
        // The agent's `OutputType` is `@Schema`-decorated, so the runner
        // routed through chat completions (LM Studio's native chat can't
        // honor `json_schema`). The result decoded means both:
        //   - the fallback dispatch fired, and
        //   - LM Studio honored `response_format` server-side.
        #expect(!result.finalOutput.colour.isEmpty)
        #expect(result.finalOutput.confidence.isFinite)
    }
}
