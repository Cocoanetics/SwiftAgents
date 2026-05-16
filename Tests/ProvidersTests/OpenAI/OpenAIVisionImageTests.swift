import Foundation
@testable import Providers
import Testing

struct OpenAIVisionImageTests {
    private let remoteVisionImageURL = "https://i0.wp.com/www.cocoanetics.com/files/iWoman.png?w=150&ssl=1"
    private let openAIModel = "gpt-4.1-mini"
    private let systemPrompt = "Describe any image attachments in a short sentence."

    @Test("OpenAI inline vision", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func openAIInlineImageUnderstanding() async throws {
        let client = try OpenAI(apiKey: #require(APIKey.openAI))
        let system = ChatMessage(role: .system, content: .text(systemPrompt))
        let user = try VisionImageTestHelpers.imageOnlyMessage()
        let response = try await client.createChatCompletion(model: openAIModel, messages: [system, user], store: true)
        let choice = try #require(response.choices.first, "Response contained no choices")
        let content = VisionImageTestHelpers.text(from: choice.message)
        #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("OpenAI remote vision", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func openAIRemoteImageUnderstanding() async throws {
        let client = try OpenAI(apiKey: #require(APIKey.openAI))
        let system = ChatMessage(role: .system, content: .text(systemPrompt))
        let user = VisionImageTestHelpers.remoteImageMessage(url: remoteVisionImageURL)
        let response = try await client.createChatCompletion(model: openAIModel, messages: [system, user], store: true)
        let choice = try #require(response.choices.first, "Response contained no choices")
        let content = VisionImageTestHelpers.text(from: choice.message)
        #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("OpenAI Responses inline vision", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func openAIResponsesInlineImageUnderstanding() async throws {
        let client = try OpenAI(apiKey: #require(APIKey.openAI))
        let fixtureData = try VisionImageTestHelpers.visionFixtureData()
        let dataURL = VisionImageTestHelpers.responseDataURL(for: fixtureData, mimeType: "image/png")
        let input = VisionImageTestHelpers.responseInput(
            prompt: "What is shown in this image?",
            attachments: [.inputImage(dataURL)]
        )
        let response = try await client.createResponse(
            input: input,
            model: openAIModel,
            instructions: systemPrompt,
            store: true,
            textFormat: .text
        )
        let content = VisionImageTestHelpers.responseText(from: response)
        #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("OpenAI Responses remote vision", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func openAIResponsesRemoteImageUnderstanding() async throws {
        let client = try OpenAI(apiKey: #require(APIKey.openAI))
        let imageURL = try #require(URL(string: remoteVisionImageURL), "Invalid remote vision URL")
        let input = VisionImageTestHelpers.responseInput(
            prompt: "What is shown in this online image?",
            attachments: [.inputImage(imageURL)]
        )
        let response = try await client.createResponse(
            input: input,
            model: openAIModel,
            instructions: systemPrompt,
            store: true,
            textFormat: .text
        )
        let content = VisionImageTestHelpers.responseText(from: response)
        #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("OpenAI Responses uploaded vision", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func openAIResponsesUploadedImageUnderstanding() async throws {
        let client = try OpenAI(apiKey: #require(APIKey.openAI))
        let fixtureData = try VisionImageTestHelpers.visionFixtureData()
        let uploaded = try await client.uploadFile(
            data: fixtureData,
            filename: "vision-response.png",
            mimeType: "image/png",
            purpose: .vision
        )
        let input = VisionImageTestHelpers.responseInput(
            prompt: "What is shown in the uploaded image?",
            attachments: [.inputImageFileID(uploaded.id)]
        )
        let response = try await client.createResponse(
            input: input,
            model: openAIModel,
            instructions: systemPrompt,
            store: true,
            textFormat: .text
        )
        let content = VisionImageTestHelpers.responseText(from: response)
        #expect(!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
