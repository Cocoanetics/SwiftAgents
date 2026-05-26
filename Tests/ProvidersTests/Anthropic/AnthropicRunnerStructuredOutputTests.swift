//
//  AnthropicRunnerStructuredOutputTests.swift
//  ProvidersTests
//
//  Structured-output coverage via the Agents SDK Runner against
//  Anthropic. Anthropic does NOT currently honor `textFormat` /
//  `responseFormat` server-side (`Anthropic+Responses.swift` and
//  `Anthropic+ChatCompletion.swift` both ignore the parameter with an
//  underscore arg), so this test exercises the prompt-engineering
//  path: the agent has an `@Schema`-decorated `OutputType` and the
//  prompt explicitly asks for matching JSON. If Claude returns clean
//  JSON, the Runner decodes it and the test passes.
//
//  If structured output ever lands natively on Anthropic, this test
//  should keep passing — the schema constraint would just become
//  server-enforced rather than prompt-suggested.
//
//  Gated on ANTHROPIC_API_KEY.
//

import Foundation
@testable import Providers
import SwiftMCP
import Testing

@Schema
private struct AnthropicColourGuess: Codable, Equatable {
    let colour: String
    let confidence: Double
}

private final class AnthropicColourGuessAgent: Agent {
    typealias OutputType = AnthropicColourGuess
    let name = "AnthropicColourGuesser"
    let model: String? = "anthropic/claude-haiku-4-5"
    let instructions = """
    Decide what colour a thing usually is. Reply with ONLY a JSON object
    matching this schema: { "colour": <string>, "confidence": <number> }.
    No prose, no markdown fences.
    """
    let modelSettings = ModelSettings(temperature: 0)
}

struct AnthropicRunnerStructuredOutputTests {
    @Test(
        "Runner produces a @Schema-decoded result from Anthropic via prompt-driven JSON",
        .enabled(if: APIKey.hasAnthropic, "Requires ANTHROPIC_API_KEY")
    )
    func runnerStructuredOutput() async throws {
        let agent = AnthropicColourGuessAgent()
        let result = try await Runner.run(
            agent: agent,
            input: "What colour is grass?",
            maxTurns: 3
        )
        // Decoded result means Claude returned valid JSON shaped like
        // the @Schema decl — the prompt-driven structured-output path
        // worked. If Anthropic ever gains native schema enforcement
        // this assertion is still correct.
        #expect(!result.finalOutput.colour.isEmpty)
        #expect(result.finalOutput.confidence.isFinite)
    }
}
