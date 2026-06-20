//
//  AnthropicFilesTests.swift
//  ProvidersTests
//
//  Anthropic Files API: the `file` image source, the converter wiring that
//  turns a `file_id` input into an Anthropic image block, the beta-header
//  trigger, and a live upload → reference-by-id → vision → delete round-trip.
//

import Foundation
@testable import Agents
@testable import Providers
import Testing

private let anthropicVisionModel = "claude-haiku-4-5"

struct AnthropicFilesTests {
    /// First `file`-sourced image id found in a converted message list.
    private func fileSourceID(in messages: [AnthropicMessage]) -> String? {
        for message in messages {
            guard case let .blocks(blocks) = message.content else { continue }
            for block in blocks {
                if case let .image(image) = block, image.source.type == "file" {
                    return image.source.fileID
                }
            }
        }
        return nil
    }

    // MARK: - Wire format

    @Test("Image file source encodes as { type: file, file_id }")
    func fileSourceEncodes() throws {
        let block = AnthropicContentBlock.image(.init(source: .file("file_abc123")))
        let json = try #require(String(data: JSONEncoder().encode(block), encoding: .utf8))

        #expect(json.contains("\"type\":\"file\""))
        #expect(json.contains("\"file_id\":\"file_abc123\""))
        #expect(!json.contains("media_type"))
        #expect(!json.contains("\"url\""))
    }

    @Test("AnthropicFile decodes the documented upload response")
    func anthropicFileDecodes() throws {
        let json = """
        {
          "id": "file_011CNha8iCJcU1wXNR6q4V8w",
          "type": "file",
          "filename": "image.png",
          "mime_type": "image/png",
          "size_bytes": 1024000,
          "created_at": "2025-01-01T00:00:00Z",
          "downloadable": false
        }
        """
        let file = try JSONDecoder().decode(AnthropicFile.self, from: Data(json.utf8))
        #expect(file.id == "file_011CNha8iCJcU1wXNR6q4V8w")
        #expect(file.mimeType == "image/png")
        #expect(file.sizeBytes == 1_024_000)
        #expect(file.downloadable == false)
    }

    // MARK: - Converter wiring

    @Test("Responses input .inputImageFileID maps to an Anthropic file source")
    func responseInputFileIDMapsToFileSource() {
        let input: Response.Input = .array([
            .message(.init(role: .user, content: [
                .inputText("Describe."),
                .inputImageFileID("file_abc123")
            ]))
        ])
        let (_, messages) = Anthropic.convertResponseInput(input, instructions: nil)
        #expect(fileSourceID(in: messages) == "file_abc123")
    }

    @Test("Chat-message file part maps to an Anthropic file source")
    func chatMessageFilePartMapsToFileSource() {
        let message = ChatMessage(role: .user, content: .parts([
            ChatMessage.ContentPart(fileID: "file_abc123")
        ]))
        let (_, messages) = Anthropic.convertChatMessages([message])
        #expect(fileSourceID(in: messages) == "file_abc123")
    }

    // MARK: - Beta-header trigger

    @Test("referencesUploadedFiles detects a file image block")
    func referencesUploadedFiles() {
        let withFile = AnthropicMessagesRequest(
            model: anthropicVisionModel,
            messages: [.init(role: .user, content: .blocks([.image(.init(source: .file("file_x")))]))],
            maxTokens: 100
        )
        #expect(withFile.referencesUploadedFiles)

        let textOnly = AnthropicMessagesRequest(
            model: anthropicVisionModel,
            messages: [.init(role: .user, content: .text("hi"))],
            maxTokens: 100
        )
        #expect(!textOnly.referencesUploadedFiles)
    }

    // MARK: - Live round-trip

    @Test(
        "Files API: upload image, reference by file_id for vision, delete",
        .enabled(if: APIKey.hasAnthropic, "Requires ANTHROPIC_API_KEY")
    )
    func uploadReferenceAndDelete() async throws {
        let client = try Anthropic(credential: Credential.apiKey(#require(APIKey.anthropic as String?)))
        let bundleURL = try #require(
            Bundle.module.url(forResource: "vision-test", withExtension: "png"),
            "vision-test fixture is required"
        )
        let imageData = try Data(contentsOf: bundleURL)

        let uploaded = try await client.uploadFile(
            data: imageData,
            filename: "vision-test.png",
            mimeType: "image/png"
        )
        #expect(uploaded.id.hasPrefix("file_"))

        let agent = BasicAgent(
            name: "AnthropicVision",
            model: anthropicVisionModel,
            instructions: "You are a concise visual assistant. Describe what you see briefly.",
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 200)
        )
        let input: Response.Input = .array([
            .message(.init(role: .user, content: [
                .inputText("What objects are shown in this image? Answer in one short sentence."),
                .inputImageFileID(uploaded.id)
            ]))
        ])

        let result = try await Runner.run(agent: agent, input: input, maxTurns: 2, config: RunConfig(api: client))
        let lower = result.finalOutput.lowercased()
        #expect(lower.contains("dice") || lower.contains("die"),
                "expected the model to describe the dice fixture; got: \(result.finalOutput)")

        #expect(try await client.deleteFile(id: uploaded.id))
    }
}
