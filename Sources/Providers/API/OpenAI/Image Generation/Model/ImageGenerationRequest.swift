//
//  ImageGenerationRequest.swift
//
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

/// Request model for image generation sent to OpenAI API
public struct ImageGenerationRequest: Codable {
    let prompt: String
    let model: String // The actual model identifier string
    let n: Int // API parameter name is 'n'
    let size: String?
    let quality: String?
    let responseFormat: String?
    let style: String?
    let background: String?
    let moderation: String?
    let outputCompression: Int?
    let outputFormat: String?
    let user: String?

    /// Simplified initializer taking only raw values
    init(
        prompt: String,
        model: String,
        n: Int, // API parameter name is 'n'
        size: String? = nil,
        quality: String? = nil,
        responseFormat: String? = nil,
        style: String? = nil,
        background: String? = nil,
        moderation: String? = nil,
        outputCompression: Int? = nil,
        outputFormat: String? = nil,
        user: String? = nil
    ) {
        self.prompt = prompt
        self.model = model
        self.n = n // API parameter name is 'n'
        self.size = size
        self.quality = quality
        self.responseFormat = responseFormat
        self.style = style
        self.background = background
        self.moderation = moderation
        self.outputCompression = outputCompression
        self.outputFormat = outputFormat
        self.user = user
    }
}
