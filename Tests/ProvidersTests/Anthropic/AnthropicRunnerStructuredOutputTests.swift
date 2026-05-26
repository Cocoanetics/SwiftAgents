//
//  AnthropicRunnerStructuredOutputTests.swift
//  ProvidersTests
//
//  Structured-output coverage via the Agents SDK Runner against
//  Anthropic. Exercises Anthropic's NATIVE structured outputs feature
//  (`output_config.format` with `type: "json_schema"`, per
//  https://platform.claude.com/docs/en/build-with-claude/structured-outputs)
//  rather than prompt-driven JSON. The schema constraint is enforced
//  server-side via grammar-constrained sampling — Claude can't return
//  text that doesn't match the schema, so the agent's `instructions`
//  contain no JSON shape hints.
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
    // No JSON hints in the prompt — the schema is enforced via
    // `output_config.format`. If we accidentally regress to plain text
    // mode, the decoder fails and this test catches it.
    let instructions = "Decide what colour a thing usually is."
    let modelSettings = ModelSettings(temperature: 0)
}

@Suite(.serialized)
struct AnthropicRunnerStructuredOutputTests {
    @Test(
        "Runner produces a @Schema-decoded result from Anthropic via output_config",
        .enabled(if: APIKey.hasAnthropic, "Requires ANTHROPIC_API_KEY")
    )
    func runnerStructuredOutput() async throws {
        let agent = AnthropicColourGuessAgent()
        let result = try await Runner.run(
            agent: agent,
            input: "What colour is grass?",
            maxTurns: 3
        )
        // Server-side grammar-constrained sampling guarantees the
        // response is parseable JSON matching the schema. If
        // `output_config` ever gets dropped on the floor again, the
        // model would respond in prose ("Grass is green.") and decode
        // would fail.
        #expect(!result.finalOutput.colour.isEmpty)
        #expect(result.finalOutput.confidence.isFinite)
    }
}
