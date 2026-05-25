//
//  AnthropicMessagesResponse.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.05.26.
//

import Foundation

/// Response body returned by `POST /v1/messages` (non-streaming).
public struct AnthropicMessagesResponse: Codable, Sendable {
    public let id: String
    public let type: String
    public let role: String
    public let model: String
    public let content: [AnthropicContentBlock]
    public let stopReason: AnthropicStopReason?
    public let stopSequence: String?
    public let usage: AnthropicUsage?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case role
        case model
        case content
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
        case usage
    }

    public init(
        id: String,
        type: String = "message",
        role: String = "assistant",
        model: String,
        content: [AnthropicContentBlock],
        stopReason: AnthropicStopReason?,
        stopSequence: String?,
        usage: AnthropicUsage?
    ) {
        self.id = id
        self.type = type
        self.role = role
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.stopSequence = stopSequence
        self.usage = usage
    }
}
