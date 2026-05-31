//
//  GeminiImageAgentTests.swift
//  SwiftAgents
//
//  End-to-end coverage of image generation through the Agents layer against
//  Gemini. Unlike the OpenAI path (the Responses `image_generation` tool),
//  Gemini shapes image output via the request (`responseModalities` +
//  `imageConfig`) and returns bytes inline on a normal completion. `ImageAgent`
//  drives both providers through the same `RequestedMedia` intent; this suite
//  exercises the Gemini realization (request shaping + inline-image extraction
//  → `GeneratedFile`).
//

import Foundation
@testable import Agents
@testable import Providers
import Testing

struct GeminiImageAgentTests {
    private let model = "gemini-3-pro-image-preview"

    @Test("ImageAgent generates an image via Gemini", .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY"))
    func generatesImage() async throws {
        let agent = ImageAgent(
            name: "ImageGen",
            model: model,
            instructions: "Generate the requested image."
        )

        let result = try await Runner.run(
            agent: agent,
            input: "A photorealistic mountain landscape at sunset, vivid colors."
        )

        #expect(result.finalOutput.mimeType.hasPrefix("image/"))
        #expect(result.finalOutput.data.count > 1024, "image unexpectedly small")

        // Persist for manual inspection, mirroring the other image suites.
        let ext = result.finalOutput.mimeType.preferredFilenameExtension() ?? "bin"
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gemini-imageagent-\(UUID().uuidString.prefix(8)).\(ext)")
        try result.finalOutput.data.write(to: url)
    }
}
