import Foundation // For ProcessInfo
@testable import Agents
@testable import Providers
import SwiftMCP
import Tracing
import Testing // New import for Swift-Testing

struct AgentGuardrailTest {
    /// Guardrail, Agent, and Output definitions (can remain top-level or be nested if preferred)
    struct ForbiddenWordGuardrail: InputGuardrail {
        let name: String
        let forbiddenWord: String
        func evaluate(_ input: String) async throws -> InputGuardrailResult {
            let triggered = input.localizedCaseInsensitiveContains(forbiddenWord)
            try await Task.sleep(nanoseconds: 10_000_000) // Reduced sleep further for faster tests
            return InputGuardrailResult(
                tripwireTriggered: triggered,
                metadata: ["forbiddenWord": JSONValue(forbiddenWord)]
            )
        }
    }

    @Schema
    struct MessageOutput: Codable, Equatable {
        let reasoning: String
        let response: String
        // No CodingKeys remap — `@Schema` emits the Swift property name as
        // the wire key, so the model returns "userName" verbatim and the
        // decoder must look for the same. A `user_name` mapping here causes
        // every turn to fail to decode and the run hits maxTurns.
        let userName: String
    }

    final class MessageOutputAgent: Agent {
        typealias OutputType = MessageOutput
        let name = "MessageOutputAgent"
        let instructions = "You are a helpful assistant."
        let outputGuardrails: [any OutputGuardrail]

        init() {
            outputGuardrails = [SensitiveDataOutputGuardrail()]
        }
    }

    struct SensitiveDataOutputGuardrail: OutputGuardrail {
        let name: String = "SensitiveDataCheck"
        func evaluate(_ output: any Sendable, agent _: any Agent) async throws -> OutputGuardrailFunctionOutput {
            guard let message = output as? MessageOutput else {
                return OutputGuardrailFunctionOutput(
                    metadata: ["type_mismatch": JSONValue(true)],
                    tripwireTriggered: false
                )
            }
            let containsSensitive = message.response.lowercased().contains("phone number") || message.response
                .lowercased().contains("650")
            return OutputGuardrailFunctionOutput(
                metadata: ["contains_sensitive": JSONValue(containsSensitive)],
                tripwireTriggered: containsSensitive
            )
        }
    }

    @Test("Input Guardrail Allows Safe Input", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func agentWithInputGuardrail_allowsSafeInput() async throws {
        try await withTrace(name: "Input Guardrail Allows Safe Input") {
            let guardrail = ForbiddenWordGuardrail(name: "NoBanana", forbiddenWord: "banana")
            let agent = BasicAgent(
                name: "Echo Agent",
                instructions: "Echo back whatever the user says.",
                inputGuardrails: [guardrail]
            )

            let result = try await Runner.run(agent: agent, input: "hello world", config: RunConfig())
            #expect(result.finalOutput.contains("hello world"), "Agent should echo the input")
        }
    }

    @Test("Input Guardrail Triggers On Forbidden Word", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func agentWithInputGuardrail_triggersOnForbiddenWord() async throws {
        try await withTrace(name: "Input Guardrail Triggers On Forbidden Word") {
            let guardrail = ForbiddenWordGuardrail(name: "NoBanana", forbiddenWord: "banana")
            let agent = BasicAgent(
                name: "Echo Agent",
                instructions: "Echo back whatever the user says.",
                inputGuardrails: [guardrail]
            )

            do {
                _ = try await Runner.run(agent: agent, input: "I like banana smoothies", config: RunConfig())
                Issue.record("Expected InputGuardrailTripwireTriggered to be thrown")
            } catch let error as InputGuardrailTripwireTriggered {
                #expect(error.guardrailName == "NoBanana")
                #expect(error.result.tripwireTriggered == true)
                let metadata = try #require(error.result.metadata, "Expected metadata for guardrail")
                let forbidden = try #require(
                    metadata["forbiddenWord"]?.jsonObject as? String,
                    "Expected forbiddenWord metadata"
                )
                #expect(forbidden == "banana")
            } catch {
                Issue.record("Caught unexpected error: \(error) - \(error.localizedDescription)")
            }
        }
    }

    @Test("Output Guardrail Triggers On Sensitive Data", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func agentWithOutputGuardrail_triggersOnSensitiveData() async throws {
        try await withTrace(name: "Output Guardrail Triggers On Sensitive Data") {
            let agent = MessageOutputAgent()
            let input = "My phone number is 650-123-4567. Where do you think I live?"

            do {
                _ = try await Runner.run(agent: agent, input: input)
                Issue.record("Expected OutputGuardrailTripwireTriggered to be thrown")
            } catch let error as OutputGuardrailTripwireTriggered {
                #expect(error.guardrailName == "SensitiveDataCheck")
                #expect(error.result.tripwireTriggered == true)
                let metadata = try #require(error.result.metadata, "Expected metadata for guardrail")
                let containsSensitive = try #require(
                    metadata["contains_sensitive"]?.jsonObject as? Bool,
                    "Expected contains_sensitive metadata"
                )
                #expect(containsSensitive == true, "The 'contains_sensitive' metadata should be true.")
            } catch {
                Issue.record("Caught unexpected error: \(error) - \(error.localizedDescription)")
            }
        }
    }
}
