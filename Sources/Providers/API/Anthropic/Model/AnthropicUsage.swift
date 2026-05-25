//
//  AnthropicUsage.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.05.26.
//

import Foundation

/// Token accounting returned alongside a Messages API response.
public struct AnthropicUsage: Codable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheCreationInputTokens: Int?
    public let cacheReadInputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    public init(
        inputTokens: Int?,
        outputTokens: Int?,
        cacheCreationInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }
}
