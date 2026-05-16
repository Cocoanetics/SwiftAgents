import Foundation
@testable import Providers
import Testing

struct VisionImageTests {
    private let remoteVisionImageURL = "https://i0.wp.com/www.cocoanetics.com/files/iWoman.png?w=150&ssl=1"
    private let googleModel = "gemini-2.5-flash"
    private let openAIModel = "gpt-4.1-mini"

    @Test("Google inline vision", .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY"))
    func googleInlineImageUnderstanding() async throws {
        let google = try GoogleAPI(apiKey: #require(APIKey.gemini as String?))
        let system = ChatMessage(role: .system, content: .text("Describe any image attachments in a short sentence."))
        let user = try imageOnlyMessage()
        let response = try await google.createChatCompletion(model: googleModel, messages: [system, user])
        let choice = try #require(response.choices.first, "Response contained no choices")
        let content = text(from: choice.message)
        // print("[Google Vision Response] \(content)")
        #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Google remote vision", .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY"))
    func googleRemoteImageUnderstanding() async throws {
        let google = try GoogleAPI(apiKey: #require(APIKey.gemini as String?))
        let fixtureURL = try #require(
            Bundle.module.url(forResource: "vision-test", withExtension: "png"),
            "vision-test fixture is required"
        )
        let fixtureData = try Data(contentsOf: fixtureURL)
        let uploaded = try await google.uploadFile(
            data: fixtureData,
            filename: "vision-remote.png",
            mimeType: "image/png"
        )
        let fileURI = try #require(uploaded.uri, "Uploaded file missing uri")
        let system = ChatMessage(role: .system, content: .text("Describe any image attachments in a short sentence."))
        let user = remoteImageMessage(url: fileURI, mimeType: "image/png")
        let response = try await google.createChatCompletion(model: googleModel, messages: [system, user])
        let choice = try #require(response.choices.first, "Response contained no choices")
        let content = text(from: choice.message)
        // print("[Google Vision Remote Response] \(content)")
        #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("OpenAI inline vision", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func openAIInlineImageUnderstanding() async throws {
        let client = try OpenAI(apiKey: #require(APIKey.openAI as String?))
        let system = ChatMessage(role: .system, content: .text("Describe any image attachments in a short sentence."))
        let user = try imageOnlyMessage()
        let response = try await client.createChatCompletion(model: openAIModel, messages: [system, user], store: true)
        let choice = try #require(response.choices.first, "Response contained no choices")
        let content = text(from: choice.message)
        // print("[OpenAI Vision Response] \(content)")
        #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("OpenAI remote vision", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func openAIRemoteImageUnderstanding() async throws {
        let client = try OpenAI(apiKey: #require(APIKey.openAI as String?))
        let system = ChatMessage(role: .system, content: .text("Describe any image attachments in a short sentence."))
        let user = remoteImageMessage(url: remoteVisionImageURL)
        let response = try await client.createChatCompletion(model: openAIModel, messages: [system, user], store: true)
        let choice = try #require(response.choices.first, "Response contained no choices")
        let content = text(from: choice.message)
        // print("[OpenAI Vision Remote Response] \(content)")
        #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Helpers

    private func imageOnlyMessage() throws -> ChatMessage {
        let url = try #require(
            Bundle.module.url(forResource: "vision-test", withExtension: "png"),
            "vision-test fixture is required"
        )
        let data = try Data(contentsOf: url)
        let textPart = ChatMessage.ContentPart(text: "What is shown in this image?")
        let imagePart = ChatMessage.ContentPart.imageDataPart(mimeType: "image/png", data: data)
        return ChatMessage(role: .user, content: .parts([textPart, imagePart]))
    }

    private func remoteImageMessage(url: String, mimeType: String? = nil) -> ChatMessage {
        let textPart = ChatMessage.ContentPart(text: "What is shown in this online image?")
        let remotePart = ChatMessage.ContentPart(imageURL: url, mimeType: mimeType)
        return ChatMessage(role: .user, content: .parts([textPart, remotePart]))
    }

    private func text(from message: ChatMessage) -> String {
        if let text = message.textContent?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        if let parts = message.contentParts,
            let joined = ChatMessage.ContentPart.joinedText(from: parts)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !joined.isEmpty {
            return joined
        }
        fatalError("Message has no textual content")
    }
}
