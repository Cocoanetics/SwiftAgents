//
//  AnthropicStreamEvent.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.05.26.
//
//  See: https://platform.claude.com/docs/en/api/messages-streaming

import Foundation
import SwiftMCP

/// One SSE event emitted by `POST /v1/messages` when `"stream": true`.
///
/// The stream flow is:
/// 1. `messageStart` (with a `Message` whose `content` is empty)
/// 2. For each content block: `contentBlockStart`, then 0+
///    `contentBlockDelta`s, then `contentBlockStop`
/// 3. One or more `messageDelta`s (stop_reason / usage updates)
/// 4. `messageStop`
/// 5. Optional `ping` events interleaved anywhere; an `error` event may
///    arrive at any time.
public enum AnthropicStreamEvent: Sendable {
    case messageStart(MessageStart)
    case contentBlockStart(ContentBlockStart)
    case contentBlockDelta(ContentBlockDelta)
    case contentBlockStop(ContentBlockStop)
    case messageDelta(MessageDelta)
    case messageStop
    case ping
    case error(AnthropicErrorDetail)
    case unknown(type: String)

    public struct MessageStart: Codable, Sendable {
        public let type: String
        public let message: AnthropicMessagesResponse
    }

    public struct ContentBlockStart: Codable, Sendable {
        public let type: String
        public let index: Int
        public let contentBlock: AnthropicContentBlock

        private enum CodingKeys: String, CodingKey {
            case type
            case index
            case contentBlock = "content_block"
        }
    }

    public struct ContentBlockDelta: Codable, Sendable {
        public let type: String
        public let index: Int
        public let delta: Delta

        public enum Delta: Codable, Sendable {
            case textDelta(String)
            case inputJsonDelta(String)
            case thinkingDelta(String)
            case signatureDelta(String)
            case unknown(type: String)

            private enum CodingKeys: String, CodingKey {
                case type
                case text
                case partialJson = "partial_json"
                case thinking
                case signature
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let type = try container.decode(String.self, forKey: .type)
                switch type {
                    case "text_delta":
                        self = try .textDelta(container.decode(String.self, forKey: .text))
                    case "input_json_delta":
                        self = try .inputJsonDelta(container.decode(String.self, forKey: .partialJson))
                    case "thinking_delta":
                        self = try .thinkingDelta(container.decode(String.self, forKey: .thinking))
                    case "signature_delta":
                        self = try .signatureDelta(container.decode(String.self, forKey: .signature))
                    default:
                        self = .unknown(type: type)
                }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                    case let .textDelta(text):
                        try container.encode("text_delta", forKey: .type)
                        try container.encode(text, forKey: .text)
                    case let .inputJsonDelta(partial):
                        try container.encode("input_json_delta", forKey: .type)
                        try container.encode(partial, forKey: .partialJson)
                    case let .thinkingDelta(thinking):
                        try container.encode("thinking_delta", forKey: .type)
                        try container.encode(thinking, forKey: .thinking)
                    case let .signatureDelta(signature):
                        try container.encode("signature_delta", forKey: .type)
                        try container.encode(signature, forKey: .signature)
                    case let .unknown(type):
                        try container.encode(type, forKey: .type)
                }
            }
        }
    }

    public struct ContentBlockStop: Codable, Sendable {
        public let type: String
        public let index: Int
    }

    public struct MessageDelta: Codable, Sendable {
        public let type: String
        public let delta: Delta
        public let usage: AnthropicUsage?

        public struct Delta: Codable, Sendable {
            public let stopReason: AnthropicStopReason?
            public let stopSequence: String?

            private enum CodingKeys: String, CodingKey {
                case stopReason = "stop_reason"
                case stopSequence = "stop_sequence"
            }
        }
    }
}
