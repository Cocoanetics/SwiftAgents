import Foundation
import Testing
@testable import Providers

struct GoogleVisionImageTests {
	private let googleModel = "gemini-2.5-flash"

	@Test("Google inline vision", .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY"))
	func googleInlineImageUnderstanding() async throws {
		let google = GoogleAPI(apiKey: APIKey.gemini!)
		let system = ChatMessage(role: .system, content: .text("Describe any image attachments in a short sentence."))
		let user = try VisionImageTestHelpers.imageOnlyMessage()
		let response = try await google.createChatCompletion(model: googleModel, messages: [system, user])
		let choice = try #require(response.choices.first, "Response contained no choices")
		let content = VisionImageTestHelpers.text(from: choice.message)
		#expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
	}

	@Test("Google remote vision", .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY"))
	func googleRemoteImageUnderstanding() async throws {
		let google = GoogleAPI(apiKey: APIKey.gemini!)
		let fixtureURL = try #require(Bundle.module.url(forResource: "vision-test", withExtension: "png"), "vision-test fixture is required")
		let fixtureData = try Data(contentsOf: fixtureURL)
		let uploaded = try await google.uploadFile(data: fixtureData, filename: "vision-remote.png", mimeType: "image/png")
		let fileURI = try #require(uploaded.uri, "Uploaded file missing uri")
		let system = ChatMessage(role: .system, content: .text("Describe any image attachments in a short sentence."))
		let user = VisionImageTestHelpers.remoteImageMessage(url: fileURI, mimeType: "image/png")
		let response = try await google.createChatCompletion(model: googleModel, messages: [system, user])
		let choice = try #require(response.choices.first, "Response contained no choices")
		let content = VisionImageTestHelpers.text(from: choice.message)
		#expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
	}
}
