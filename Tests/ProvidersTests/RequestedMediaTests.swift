//
//  RequestedMediaTests.swift
//  SwiftAgents
//
//  Offline coverage for the provider-neutral requested-media abstraction and
//  the Gemini-style inline-image output pipeline it feeds: the `[RequestedMedia]`
//  helpers, the `OutputImage` content carrier, `firstGeneratedFile`, the
//  chat-completion → Response adapter, and `ImageAgent`'s default intent. None
//  of these touch the network.
//

import Foundation
@testable import Agents
@testable import Providers
import Testing

struct RequestedMediaTests {
    // PNG signature — a recognisable, decodable byte sequence to stand in for
    // real image bytes.
    private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])

    // MARK: - [RequestedMedia] helpers

    @Test("requestsImage / firstImageOptions read the image modality")
    func mediaHelpers() {
        let media: [RequestedMedia] = [.text, .image(ImageOptions(size: "2K", aspectRatio: "16:9"))]
        #expect(media.requestsImage)
        #expect(media.firstImageOptions == ImageOptions(size: "2K", aspectRatio: "16:9"))

        let textOnly: [RequestedMedia] = [.text]
        #expect(!textOnly.requestsImage)
        #expect(textOnly.firstImageOptions == nil)
    }

    @Test("GenerationOptions defaults to an empty media list")
    func generationOptionsDefault() {
        #expect(GenerationOptions().requestedMedia.isEmpty)
        #expect(GenerationOptions(requestedMedia: [.image(ImageOptions())]).requestedMedia.requestsImage)
    }

    // MARK: - OutputImage wire format

    @Test("MessageContent.outputImage round-trips through Codable")
    func outputImageCodableRoundTrip() throws {
        let original = OutputItem.MessageContent.outputImage(
            OutputItem.OutputImage(data: Self.pngBytes, mimeType: "image/png")
        )

        let encoded = try JSONEncoder().encode(original)

        // Wire shape: a discriminator plus base64 bytes under snake_case keys.
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("\"type\":\"output_image\""))
        #expect(json.contains("\"mime_type\":\"image\\/png\""))

        let decoded = try JSONDecoder().decode(OutputItem.MessageContent.self, from: encoded)
        guard case let .outputImage(image) = decoded else {
            Issue.record("Expected .outputImage, got \(decoded)")
            return
        }
        #expect(image.data == Self.pngBytes)
        #expect(image.mimeType == "image/png")
    }

    // MARK: - firstGeneratedFile

    @Test("firstGeneratedFile surfaces an inline outputImage on a message")
    func firstGeneratedFileFromOutputImage() {
        let items: [OutputItem] = [
            .message(OutputItem.MessageOutput(
                id: "m1",
                role: .assistant,
                status: .completed,
                content: [.outputImage(OutputItem.OutputImage(data: Self.pngBytes, mimeType: "image/png"))]
            ))
        ]

        let file = items.firstGeneratedFile
        #expect(file?.data == Self.pngBytes)
        #expect(file?.mimeType == "image/png")
        #expect(file?.id == nil)
    }

    // MARK: - chat-completion → Response adapter

    @Test("toResponse carries a Gemini-style inline image part to a GeneratedFile")
    func toResponseSurfacesInlineImage() {
        let dataURL = "data:image/png;base64,\(Self.pngBytes.base64EncodedString())"
        let message = ChatMessage(role: .assistant, content: .parts([
            ChatMessage.ContentPart(imageURL: dataURL)
        ]))
        let completion = ChatCompletionResponse(
            id: "id",
            object: "chat.completion",
            created: Date(timeIntervalSince1970: 0),
            model: "gemini-3-pro-image-preview",
            usage: nil,
            choices: [.init(message: message, finishReason: .stop, index: 0)]
        )

        let agent = ImageAgent(name: "t", model: "gemini-3-pro-image-preview")
        let response = completion.toResponse(
            input: .text("draw a sloth"),
            agent: agent,
            modelSettings: agent.modelSettings
        )

        let file = response.output.firstGeneratedFile
        #expect(file != nil, "inline image part should surface as a GeneratedFile")
        #expect(file?.data == Self.pngBytes)
        #expect(file?.mimeType == "image/png")
    }

    // MARK: - ImageAgent intent (the RequestsMedia protocol)

    @Test("ImageAgent declares its image intent via RequestsMedia")
    func imageAgentSetsRequestedMedia() {
        let agent = ImageAgent(name: "ImageGen", model: "gemini-3-pro-image-preview", image: ImageOptions(size: "2K"))
        #expect(agent.requestedMedia == [.image(ImageOptions(size: "2K"))])
    }

    @Test("ImageAgent's intent is reachable through the RequestsMedia protocol")
    func imageAgentConformsToRequestsMedia() {
        // The Runner discovers media intent via `agent as? RequestsMedia`.
        let agent: any Agent = ImageAgent(name: "ImageGen", image: ImageOptions(size: "1024x1024"))
        let media = (agent as? RequestsMedia)?.requestedMedia
        #expect(media == [.image(ImageOptions(size: "1024x1024"))])
    }

    // MARK: - Runner image-tool realization (the provider-specific step)

    @Test("Runner realizes an image intent as the OpenAI image_generation tool")
    func realizesImageToolForOpenAI() {
        let api = OpenAI(credential: Credential.bearer("test"))
        let media: [RequestedMedia] = [.image(ImageOptions(size: "1024x1024", quality: "low", outputFormat: "png"))]

        let tools = Runner.realizingImageTool([], for: media, api: api)

        #expect(tools.count == 1)
        guard case let .imageGeneration(tool) = tools.first else {
            Issue.record("Expected an image_generation tool, got \(tools)")
            return
        }
        #expect(tool.size == "1024x1024")
        #expect(tool.quality == "low")
        #expect(tool.outputFormat == "png")
    }

    @Test("Runner does not inject the OpenAI tool for non-OpenAI providers")
    func realizesNoToolForGemini() {
        let api = GoogleAPI(credential: Credential.googleAPIKey("test"))
        let media: [RequestedMedia] = [.image(ImageOptions(size: "2K"))]
        // Gemini shapes image output through the request, not a tool.
        #expect(Runner.realizingImageTool([], for: media, api: api).isEmpty)
    }

    @Test("Runner respects an explicit image_generation tool (no duplicate)")
    func realizationRespectsExplicitTool() {
        let api = OpenAI(credential: Credential.bearer("test"))
        let explicit = Tool.imageGeneration(ImageGenerationTool(quality: "high"))
        let media: [RequestedMedia] = [.image(ImageOptions(quality: "low"))]

        let tools = Runner.realizingImageTool([explicit], for: media, api: api)

        #expect(tools.count == 1)
        guard case let .imageGeneration(tool) = tools.first else {
            Issue.record("Expected the explicit image_generation tool")
            return
        }
        #expect(tool.quality == "high", "explicit tool's options should win")
    }

    // MARK: - Gemini responseModalities mapping

    @Test("Gemini responseModalities include every requested modality")
    func googleResponseModalitiesMapping() {
        // Text + image must keep TEXT, not collapse to image-only.
        #expect(GoogleAPI.googleResponseModalities(for: [.text, .image(ImageOptions())]) == ["TEXT", "IMAGE"])
        #expect(GoogleAPI.googleResponseModalities(for: [.image(ImageOptions())]) == ["IMAGE"])
        // Audio isn't supported on :generateContent.
        #expect(GoogleAPI.googleResponseModalities(for: [.audio(AudioOptions())]).isEmpty)
    }

    // MARK: - Streaming guard for media output

    @Test("Streaming an image agent on a chat-completion provider fails fast")
    func streamingImageOnChatProviderThrows() async {
        // GoogleAPI streams only the chat-completion shape; image output can't
        // ride that path, so the run should throw rather than loop to maxTurns.
        let api = GoogleAPI(credential: Credential.googleAPIKey("test"))
        let agent = ImageAgent(name: "ImageGen", model: "gemini-3-pro-image-preview")
        let stream = Runner.runStreamed(agent: agent, input: "a cat", config: RunConfig(api: api))

        await #expect(throws: RunnerError.mediaOutputNotStreamable) {
            for try await _ in stream.events {}
        }
    }
}
