import Foundation
import Testing
@testable import Providers

struct AssistantAPITests {
	@Test("Assistant can be created and retrieved", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
	func assistantLifecycle() async throws {
		let openAI = try TestClients.openAI()
		let assistant = try await openAI.createAssistant(
			model: "gpt-4.1-mini",
			name: "SwiftTesting Assistant",
			instructions: "Answer concisely.",
			metadata: ["scope": "swift-testing"]
		)

		let fetched = try await openAI.retrieveAssistant(id: assistant.id)
		#expect(fetched.id == assistant.id)
		#expect(fetched.metadata["scope"] == "swift-testing")

		_ = try? await openAI.deleteAssistant(id: assistant.id)
	}

	@Test("Thread run completes and yields messages", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
	func threadRunLifecycle() async throws {
		let openAI = try TestClients.openAI()
		let assistant = try await openAI.createAssistant(
			model: "gpt-4.1-mini",
			name: "SwiftTesting Runner",
			instructions: "Respond briefly."
		)

		let thread = try await openAI.createThread(messages: [
			MessageCreation(role: .user, content: "Say hello from Swift Testing.")
		])

		let run = try await openAI.createRun(threadId: thread.id, assistantId: assistant.id, temperature: 0)
		let finishedRun = try await openAI.waitUntilRunIsFinished(threadId: thread.id, runId: run.id)
		#expect(finishedRun.status == Run.Status.completed || finishedRun.status == Run.Status.requiresAction)

		let messagesResponse = try await openAI.listMessages(threadId: thread.id)
		let messages = messagesResponse.data
		#expect(!messages.isEmpty)
		#expect(messages.first?.threadId == thread.id)

		let stepsResponse = try await openAI.listRunSteps(threadId: thread.id, runId: finishedRun.id)
		let steps = stepsResponse.data
		#expect(!steps.isEmpty)

		_ = try? await openAI.deleteAssistant(id: assistant.id)
		_ = try? await openAI.deleteThread(id: thread.id)
	}
}
