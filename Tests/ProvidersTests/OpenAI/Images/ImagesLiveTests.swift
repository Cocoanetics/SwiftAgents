//
//  ImagesLiveTests.swift
//
//  Live checks against the real Images API, gated on OPENAI_API_KEY (never
//  runs in CI). Three `low` images in total. The key is never printed.
//

import Foundation
@testable import Providers
import Testing

@Suite("Images API (live)", .enabled(if: APIKey.hasOpenAI), .serialized)
struct ImagesLiveTests {
    private func makeClient() throws -> OpenAI {
        OpenAI(credential: Credential.bearer(try #require(APIKey.openAI)))
    }

    @Test("a low-quality generate at 1536x864 returns the exact pixel size", arguments: [ImageModel.flare, .sunburst])
    func generateAtCustomSize(model: ImageModel) async throws {
        let result = try await makeClient().generateImages(
            ImageRequest(prompt: "A flat red circle on white", model: model, size: "1536x864", quality: .low)
        )
        let image = try #require(result.images.first)
        let info = try #require(ImageInfo(data: image.data))
        #expect(info.width == 1536 && info.height == 864)
        #expect(result.usage != nil)
    }

    @Test("a transparent png has an alpha channel")
    func transparentPNG() async throws {
        let result = try await makeClient().generateImages(ImageRequest(
            prompt: "A single red circle, nothing else", model: .flare, size: "1024x1024",
            quality: .low, background: .transparent, outputFormat: .png
        ))
        let image = try #require(result.images.first)
        let info = try #require(ImageInfo(data: image.data))
        #expect(info.width == 1024 && info.height == 1024)
        #expect(info.hasAlpha)
    }
}
