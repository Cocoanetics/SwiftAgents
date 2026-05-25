//
//  AnthropicErrorResponse.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.05.26.
//

import Foundation

/// Error payload returned by Anthropic on non-200 responses.
///
/// Shape: `{ "type": "error", "error": { "type": "...", "message": "..." } }`
public struct AnthropicErrorResponse: Codable, Sendable {
    public let type: String
    public let error: AnthropicErrorDetail

    public init(type: String = "error", error: AnthropicErrorDetail) {
        self.type = type
        self.error = error
    }
}

public struct AnthropicErrorDetail: Codable, Sendable {
    public let type: String
    public let message: String

    public init(type: String, message: String) {
        self.type = type
        self.message = message
    }
}
