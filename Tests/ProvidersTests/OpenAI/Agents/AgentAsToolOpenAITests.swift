import Testing
@testable import Providers
import SwiftMCP

struct AgentAsToolOpenAITests {
	@Test("Agent orchestrates translations via tools", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
	func translationOrchestration() async throws {
		let spanishAgent = BasicAgent(
			name: "SpanishTranslator",
			instructions: "Translate the user's message to Spanish. Respond with ONLY the Spanish translation.",
			modelSettings: ModelSettings(temperature: 0)
		)

		let frenchAgent = BasicAgent(
			name: "FrenchTranslator",
			instructions: "Translate the user's message to French. Respond with ONLY the French translation.",
			modelSettings: ModelSettings(temperature: 0)
		)

		let orchestrator = BasicAgent(
			name: "TranslationOrchestrator",
			instructions: "Use the provided tools to translate the text into Spanish and French. Respond with clear labels for each language.",
			toolProvider: [
				spanishAgent.asToolProvider(
					toolName: "translate_to_spanish",
					toolDescription: "Translate text to Spanish."
				),
				frenchAgent.asToolProvider(
					toolName: "translate_to_french",
					toolDescription: "Translate text to French."
				)
			],
			modelSettings: ModelSettings(temperature: 0.1, toolChoice: .auto)
		)

		let userInput = "Hello, how are you today? Please translate this to Spanish and French."
		let result = try await Runner.run(agent: orchestrator, input: userInput, maxTurns: 5)

		let output = result.finalOutput.lowercased()
		#expect(!output.isEmpty)
		#expect(output.contains("spanish:") || output.contains("español"))
		#expect(output.contains("french:") || output.contains("français"))
	}
}
