//
//  AnthropicMessage.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.05.26.
//

import Foundation

/// One turn in an Anthropic Messages API conversation.
///
/// `role` is either `"user"` or `"assistant"`. `content` is either a plain
/// string (which Anthropic treats as a single text block) or an explicit array
/// of typed blocks.
public struct AnthropicMessage: Codable, Sendable {
    public let role: Role
    public let content: Content

    public init(role: Role, content: Content) {
        self.role = role
        self.content = content
    }

    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public enum Content: Codable, Sendable {
        case text(String)
        case blocks([AnthropicContentBlock])

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .text(string)
            } else {
                self = try .blocks(container.decode([AnthropicContentBlock].self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
                case let .text(string):
                    try container.encode(string)
                case let .blocks(blocks):
                    try container.encode(blocks)
            }
        }
    }
}

/// System prompt — either a plain string or an array of text blocks
/// (used for prompt caching / cache control).
public enum AnthropicSystem: Codable, Sendable {
    case text(String)
    case blocks([AnthropicTextBlock])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .text(string)
        } else {
            self = try .blocks(container.decode([AnthropicTextBlock].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
            case let .text(string):
                try container.encode(string)
            case let .blocks(blocks):
                try container.encode(blocks)
        }
    }
}
