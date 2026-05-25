//
//  AnthropicContentBlock.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.05.26.
//

import Foundation
import SwiftMCP

/// A single content block in an Anthropic message — either user input (text,
/// image, tool_result) or model output (text, tool_use, thinking).
///
/// See: https://platform.claude.com/docs/en/api/messages
public enum AnthropicContentBlock: Codable, Sendable {
    case text(AnthropicTextBlock)
    case image(AnthropicImageBlock)
    case toolUse(AnthropicToolUseBlock)
    case toolResult(AnthropicToolResultBlock)
    case thinking(AnthropicThinkingBlock)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
            case "text":
                self = try .text(AnthropicTextBlock(from: decoder))
            case "image":
                self = try .image(AnthropicImageBlock(from: decoder))
            case "tool_use":
                self = try .toolUse(AnthropicToolUseBlock(from: decoder))
            case "tool_result":
                self = try .toolResult(AnthropicToolResultBlock(from: decoder))
            case "thinking":
                self = try .thinking(AnthropicThinkingBlock(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Anthropic content block type: \(type)"
                )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
            case let .text(block):
                try block.encode(to: encoder)
            case let .image(block):
                try block.encode(to: encoder)
            case let .toolUse(block):
                try block.encode(to: encoder)
            case let .toolResult(block):
                try block.encode(to: encoder)
            case let .thinking(block):
                try block.encode(to: encoder)
        }
    }
}

/// Plain text content block.
public struct AnthropicTextBlock: Codable, Sendable {
    public let type: String
    public let text: String

    public init(text: String) {
        type = "text"
        self.text = text
    }
}

/// Image content block. Sources are either `base64` (`mediaType` + `data`) or
/// `url` (remote URL fetched server-side).
public struct AnthropicImageBlock: Codable, Sendable {
    public let type: String
    public let source: Source

    public init(source: Source) {
        type = "image"
        self.source = source
    }

    public struct Source: Codable, Sendable {
        public let type: String
        public let mediaType: String?
        public let data: String?
        public let url: String?

        private enum CodingKeys: String, CodingKey {
            case type
            case mediaType = "media_type"
            case data
            case url
        }

        public static func base64(mediaType: String, data: String) -> Source {
            Source(type: "base64", mediaType: mediaType, data: data, url: nil)
        }

        public static func url(_ url: String) -> Source {
            Source(type: "url", mediaType: nil, data: nil, url: url)
        }

        public init(type: String, mediaType: String?, data: String?, url: String?) {
            self.type = type
            self.mediaType = mediaType
            self.data = data
            self.url = url
        }
    }
}

/// Tool invocation produced by the model. `input` is a free-form JSON object.
public struct AnthropicToolUseBlock: Codable, Sendable {
    public let type: String
    public let id: String
    public let name: String
    public let input: JSONValue

    public init(id: String, name: String, input: JSONValue) {
        type = "tool_use"
        self.id = id
        self.name = name
        self.input = input
    }
}

/// Result the caller sends back for a previous `tool_use`. The content may be
/// a plain string or an array of nested content blocks (text / image).
public struct AnthropicToolResultBlock: Codable, Sendable {
    public let type: String
    public let toolUseId: String
    public let content: Content
    public let isError: Bool?

    private enum CodingKeys: String, CodingKey {
        case type
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }

    public init(toolUseId: String, content: Content, isError: Bool? = nil) {
        type = "tool_result"
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
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

/// Extended thinking block (only present when `thinking` is enabled).
public struct AnthropicThinkingBlock: Codable, Sendable {
    public let type: String
    public let thinking: String
    public let signature: String?

    public init(thinking: String, signature: String? = nil) {
        type = "thinking"
        self.thinking = thinking
        self.signature = signature
    }
}
