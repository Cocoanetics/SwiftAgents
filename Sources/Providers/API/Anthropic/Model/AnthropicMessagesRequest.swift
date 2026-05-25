//
//  AnthropicMessagesRequest.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.05.26.
//

import Foundation

/// Request body for `POST /v1/messages`.
///
/// Anthropic uses snake_case field names; the `API` base class encodes via a
/// custom snake_case strategy so plain camelCase property names work for
/// nested keys, but the explicit `CodingKeys` here makes the wire shape
/// obvious and immune to encoder-strategy changes.
public struct AnthropicMessagesRequest: Codable, Sendable {
    public let model: String
    public let messages: [AnthropicMessage]
    public let maxTokens: Int
    public let system: AnthropicSystem?
    public let temperature: Double?
    public let topP: Double?
    public let topK: Int?
    public let stopSequences: [String]?
    public let stream: Bool?
    public let tools: [AnthropicTool]?
    public let toolChoice: AnthropicToolChoice?
    public let metadata: Metadata?

    public init(
        model: String,
        messages: [AnthropicMessage],
        maxTokens: Int,
        system: AnthropicSystem? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        stopSequences: [String]? = nil,
        stream: Bool? = nil,
        tools: [AnthropicTool]? = nil,
        toolChoice: AnthropicToolChoice? = nil,
        metadata: Metadata? = nil
    ) {
        self.model = model
        self.messages = messages
        self.maxTokens = maxTokens
        self.system = system
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.stopSequences = stopSequences
        self.stream = stream
        self.tools = tools
        self.toolChoice = toolChoice
        self.metadata = metadata
    }

    public struct Metadata: Codable, Sendable {
        public let userId: String?

        private enum CodingKeys: String, CodingKey {
            case userId = "user_id"
        }

        public init(userId: String?) {
            self.userId = userId
        }
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case system
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case stopSequences = "stop_sequences"
        case stream
        case tools
        case toolChoice = "tool_choice"
        case metadata
    }
}
