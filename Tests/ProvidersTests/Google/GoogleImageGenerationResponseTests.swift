import Foundation
@testable import Providers
import Testing

struct GoogleImageGenerationResponseTests {
    @Test("Decodes real Gemini image-generation response (inlineData / camelCase)")
    func decodesRealInlineDataResponse() throws {
        let url = try TestResources.url(
            forResource: "gemini_image_generation_response",
            withExtension: "json"
        )
        let data = try Data(contentsOf: url)
        let response = try JSONDecoder().decode(GoogleGenerateContentResponse.self, from: data)

        #expect(response.modelVersion == "gemini-3-pro-image-preview")
        #expect(response.responseId == "kf4Wav6qF6Dm7M8P-cnqyAk")

        let candidate = try #require(response.candidates.first)
        #expect(candidate.finishReason == "STOP")
        #expect(candidate.index == 0)

        let content = try #require(candidate.content)
        #expect(content.role == "model")
        #expect(content.parts.count == 1)

        let part = try #require(content.parts.first)
        #expect(part.text == nil)
        #expect(part.fileData == nil)

        let inline = try #require(part.inlineData, "Image-gen response must carry inlineData")
        #expect(inline.mimeType == "image/jpeg")
        #expect(inline.data.starts(with: [0xFF, 0xD8, 0xFF]), "JPEG SOI marker")
        #expect(inline.data.count > 60_000)

        let signature = try #require(part.thoughtSignature)
        #expect(signature.count == 148504)

        let usage = try #require(response.usageMetadata)
        #expect(usage.promptTokenCount == 24)
        #expect(usage.candidatesTokenCount == 1206)
        #expect(usage.totalTokenCount == 1359)
        #expect(usage.thoughtsTokenCount == 129)

        let promptDetails = try #require(usage.promptTokensDetails)
        #expect(promptDetails.first?.modality == "TEXT")
        #expect(promptDetails.first?.tokenCount == 24)

        let candidatesDetails = try #require(usage.candidatesTokensDetails)
        #expect(candidatesDetails.first?.modality == "IMAGE")
        #expect(candidatesDetails.first?.tokenCount == 1120)
    }

    @Test("Decodes a fileData part using camelCase keys (Gemini wire format)")
    func decodesFileDataWithCamelCaseKeys() throws {
        let json = """
            {
              "candidates": [{
                "content": {
                  "role": "model",
                  "parts": [{
                    "fileData": {
                      "fileUri": "https://generativelanguage.googleapis.com/v1beta/files/abc123",
                      "mimeType": "image/png"
                    }
                  }]
                },
                "finishReason": "STOP"
              }]
            }
            """

        let response = try JSONDecoder().decode(
            GoogleGenerateContentResponse.self,
            from: Data(json.utf8)
        )

        let part = try #require(response.candidates.first?.content?.parts.first)
        let file = try #require(part.fileData, "fileData should decode from camelCase JSON")
        #expect(file.fileUri == "https://generativelanguage.googleapis.com/v1beta/files/abc123")
        #expect(file.mimeType == "image/png")
    }

    @Test("Encodes fileData as camelCase (round-trip with itself)")
    func encodesFileDataAsCamelCase() throws {
        let part = GoogleGenerateContent.Part.file(
            uri: "https://example/files/x",
            mimeType: "image/png"
        )

        let encoded = try JSONEncoder().encode(part)
        let string = try #require(String(data: encoded, encoding: .utf8))

        #expect(string.contains("\"fileUri\""))
        #expect(string.contains("\"mimeType\""))
        #expect(!string.contains("\"file_uri\""))
        #expect(!string.contains("\"mime_type\""))
    }
}
