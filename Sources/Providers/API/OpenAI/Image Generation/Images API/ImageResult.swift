//
//  ImageResult.swift
//
//  What `/v1/images/generations` and `/v1/images/edits` return.
//

import Foundation

/// Token usage of an image request.
public struct ImageUsage: Sendable, Codable, Equatable {
    public struct Details: Sendable, Codable, Equatable {
        public var textTokens: Int?
        public var imageTokens: Int?
    }

    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    public var inputTokensDetails: Details?
    public var outputTokensDetails: Details?
}

/// One generated image.
public struct GeneratedImage: Sendable, Equatable {
    /// The decoded image bytes.
    public var data: Data
    public var revisedPrompt: String?
}

/// The outcome of an image request.
public struct ImageResult: Sendable {
    public var images: [GeneratedImage]
    /// The resolved settings, as echoed by the API (falling back to what was requested).
    public var size: String?
    public var quality: String?
    public var background: String?
    public var outputFormat: String?
    public var usage: ImageUsage?
    /// Caveats for the caller, such as an experimental size.
    public var notes: [String]
    /// The `x-request-id` response header.
    public var requestID: String?
}

/// The wire shape of a successful response.
struct ImagesResponse: Decodable {
    struct Item: Decodable {
        let b64Json: String?
        let revisedPrompt: String?
    }

    let created: Int?
    let data: [Item]
    let size: String?
    let quality: String?
    let background: String?
    let outputFormat: String?
    let usage: ImageUsage?

    func result(for request: ImageRequest, notes: [String], requestID: String?) throws -> ImageResult {
        let images = try data.map { item in
            guard let encoded = item.b64Json, let bytes = Data(base64Encoded: encoded) else {
                throw ImageGenerationError.invalidResponse("an image in the response has no b64_json data")
            }
            return GeneratedImage(data: bytes, revisedPrompt: item.revisedPrompt)
        }
        return ImageResult(
            images: images,
            size: size ?? request.size?.rawValue,
            quality: quality ?? request.quality?.rawValue,
            background: background ?? request.background?.rawValue,
            outputFormat: outputFormat ?? request.outputFormat?.rawValue,
            usage: usage,
            notes: notes,
            requestID: requestID
        )
    }
}
