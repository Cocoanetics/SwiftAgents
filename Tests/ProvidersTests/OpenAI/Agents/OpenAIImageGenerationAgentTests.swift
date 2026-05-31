//
//  OpenAIImageGenerationAgentTests.swift
//  SwiftAgents
//
//  End-to-end coverage of the Responses API `image_generation` built-in tool
//  driven through the agent layer (`ImageAgent` + `Runner`). Exercises the
//  scenarios from OpenAI's image-generation guide: a plain generation,
//  multi-turn editing via `previousResponseId`, multi-turn editing by
//  referring to the prior image by ID, streamed partial images, editing from a
//  reference image, and customized output format.
//
//  The mainline model must support the image_generation tool (gpt-5 and
//  newer). Override the default with the `OPENAI_IMAGE_MODEL` environment
//  variable if the account exposes a different one.
//

import Foundation
@testable import Agents
@testable import Providers
import Testing

@Suite(.serialized)
struct OpenAIImageGenerationAgentTests {
    /// Mainline model that drives the conversation and decides to call the
    /// image_generation tool. Overridable so the suite can target whatever
    /// image-tool-capable model an account exposes.
    private var model: String {
        ProcessInfo.processInfo.environment["OPENAI_IMAGE_MODEL"] ?? "gpt-5.5"
    }

    /// PNG / JPEG magic-byte prefixes — a Linux-safe way to confirm the format
    /// without pulling in ImageIO.
    private static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    private static let jpegMagic = Data([0xFF, 0xD8, 0xFF])

    /// Sanity-checks a generated image, writes it to the temp dir for manual
    /// inspection, and returns the file URL.
    @discardableResult
    private func persist(_ file: GeneratedFile, minBytes: Int = 1024) throws -> URL {
        #expect(file.mimeType.hasPrefix("image/"), "unexpected mime type: \(file.mimeType)")
        #expect(file.data.count > minBytes, "image unexpectedly small: \(file.data.count) bytes")

        let ext = file.mimeType.preferredFilenameExtension() ?? "bin"
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openai-imagegen-\(UUID().uuidString.prefix(8)).\(ext)")
        try file.data.write(to: url)
        return url
    }

    @Test("ImageAgent generates an image", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func generate() async throws {
        let openAI = try TestClients.openAI()
        let agent = ImageAgent(
            name: "ImageGen",
            model: model,
            instructions: "Generate the requested image.",
            action: .generate,
            quality: "low",
            outputFormat: "png"
        )

        let result = try await Runner.run(
            agent: agent,
            input: "A gray tabby cat hugging an otter with an orange scarf.",
            config: RunConfig(api: openAI)
        )

        try persist(result.finalOutput)
        #expect(result.finalOutput.data.starts(with: Self.pngMagic), "expected PNG bytes")
        // The image_generation_call id is what later turns refer back to.
        #expect(result.finalOutput.id != nil)
    }

    @Test(
        "Multi-turn edit via previousResponseId",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func multiTurnViaResponseId() async throws {
        let openAI = try TestClients.openAI()
        let agent = ImageAgent(name: "ImageGen", model: model, quality: "low")

        let first = try await Runner.run(
            agent: agent,
            input: "A gray tabby cat hugging an otter with an orange scarf.",
            config: RunConfig(api: openAI)
        )
        try persist(first.finalOutput)

        let priorId = try #require(first.lastResponseId, "stateful run should expose a response id to chain")

        let second = try await Runner.run(
            agent: agent,
            input: "Now make it look photorealistic.",
            previousResponseId: priorId,
            config: RunConfig(api: openAI)
        )
        try persist(second.finalOutput)
    }

    @Test(
        "Multi-turn edit by referring to the image id",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func multiTurnViaImageId() async throws {
        let openAI = try TestClients.openAI()
        let agent = ImageAgent(name: "ImageGen", model: model, quality: "low")

        let first = try await Runner.run(
            agent: agent,
            input: "A gray tabby cat hugging an otter with an orange scarf.",
            config: RunConfig(api: openAI)
        )
        try persist(first.finalOutput)

        let imageId = try #require(first.finalOutput.id, "expected an image_generation_call id")

        // Refer back to the prior image by id alone — no previousResponseId.
        // The model edits the referenced image rather than starting fresh.
        let followUp = Response.Input.array([
            .message(.init(role: .user, text: "Now make it look photorealistic.")),
            .imageGenerationCall(OutputItem.ImageGenerationCall(id: imageId))
        ])

        let second = try await Runner.run(
            agent: agent,
            input: followUp,
            config: RunConfig(api: openAI)
        )
        try persist(second.finalOutput)
    }

    @Test(
        "Streaming yields partial images",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func streamingPartialImages() async throws {
        let openAI = try TestClients.openAI()
        let agent = ImageAgent(name: "ImageGen", model: model, quality: "low", partialImages: 2)

        let stream = Runner.runStreamed(
            agent: agent,
            input: "A river made of white owl feathers winding through a winter landscape.",
            config: RunConfig(api: openAI)
        )

        var partialCount = 0
        var sawPartialBytes = false
        var sawInProgress = false
        for try await event in stream.events {
            guard case let .rawResponseEvent(streamEvent) = event else { continue }
            switch streamEvent.object {
                case let .imageGenerationCallPartialImage(info):
                    partialCount += 1
                    sawPartialBytes = sawPartialBytes || !info.partialImageB64.isEmpty
                case .imageGenerationCallInProgress:
                    sawInProgress = true
                default:
                    continue
            }
        }

        #expect(partialCount >= 1, "expected at least one partial image with partial_images: 2")
        #expect(sawPartialBytes, "partial image events should carry bytes")
        // The tool announces itself with an in_progress event; the final image
        // arrives on the completed response rather than a dedicated
        // image_generation_call.completed event, so we don't assert on the latter.
        #expect(sawInProgress, "expected an image_generation_call.in_progress lifecycle event")
    }

    @Test(
        "Edit using a reference image",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func editWithReferenceImage() async throws {
        let openAI = try TestClients.openAI()
        let referenceData = try VisionImageTestHelpers.visionFixtureData()
        let referenceURL = VisionImageTestHelpers.responseDataURL(for: referenceData, mimeType: "image/png")

        let agent = ImageAgent(name: "ImageEditor", model: model, action: .edit, quality: "low")

        let input = Response.Input.array([
            .message(.init(role: .user, content: [
                .inputText("Add a thick bright red border around this image."),
                .inputImage(referenceURL)
            ]))
        ])

        let result = try await Runner.run(agent: agent, input: input, config: RunConfig(api: openAI))
        try persist(result.finalOutput)
    }

    @Test(
        "Customized output format (jpeg)",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func customizedOutputFormat() async throws {
        let openAI = try TestClients.openAI()
        let agent = ImageAgent(
            name: "ImageGen",
            model: model,
            action: .generate,
            size: "1024x1024",
            quality: "low",
            outputFormat: "jpeg"
        )

        let result = try await Runner.run(
            agent: agent,
            input: "A simple red circle centered on a white background.",
            config: RunConfig(api: openAI)
        )

        try persist(result.finalOutput)
        #expect(result.finalOutput.mimeType == "image/jpeg")
        #expect(result.finalOutput.data.starts(with: Self.jpegMagic), "expected JPEG bytes")
    }
}
