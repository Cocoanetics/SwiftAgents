import Testing
@testable import AgentCorp
import Foundation

struct ResponseSwiftTestingTest {

	@Test("Response in Background", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
	func testBasicCreateResponse() async throws {

		let response = try await OpenAI().createResponse(
			input: .text("Write a very long story about a unicorn and a cat that has a moral lesson."),
			model: "gpt-4.1",
			background: true
		)
		#expect(response.id != "")
		#expect(response.status == .queued || response.status == .inProgress)
		#expect(response.output.isEmpty)
	}
} 
