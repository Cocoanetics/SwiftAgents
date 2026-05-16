//
//  Chunk.swift
//
//
//  Created by Oliver Drobnik on 23.04.24.
//

import Foundation

/// Decodes a chunk of the streaming response
public struct Chunk: Codable {
    public struct Choice: Codable {
        /// The index of the choice, starting from 0.
        public let index: Int

        public struct Delta: Codable {
            public let role: Role?
            public let content: String?
            public let toolCalls: [ToolCallDelta]?

            public init(role: Role?, content: String?, toolCalls: [ToolCallDelta]?) {
                self.role = role
                self.content = content
                self.toolCalls = toolCalls
            }
        }

        public let delta: Delta

        /// The reason why the completion was finished, such as "max_tokens" or "stop".
        public var finishReason: FinishReason?

        /* BEGIN AnythingLLM workaround */

        // AnythingLLM needs finishReason NULL: https://github.com/Mintplex-Labs/anything-llm/issues/1475

        enum CodingKeys: String, CodingKey {
            case index
            case delta
            case finishReason
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(index, forKey: .index)
            try container.encode(delta, forKey: .delta)
            if finishReason != nil {
                try container.encode(finishReason, forKey: .finishReason)
            } else {
                try container.encodeNil(forKey: .finishReason)
            }
        }

        /* END AnythingLLM workaround */

        public init(index: Int, delta: Delta, finishReason: FinishReason? = nil) {
            self.index = index
            self.delta = delta
            self.finishReason = finishReason
        }
    }

    /// The ID of the completion request.
    public let id: String

    /// The type of object, which is always "chat.completion.chunk".
    public let object: String

    /// The Unix timestamp when the completion request was created.
    public let created: Date

    /// The ID of the model used to generate the completion.
    public let model: String

    /// A fingerprint identifying the system
    public var systemFingerprint: String?

    /// One or more choices of messages
    public var choices: [Choice]

    /// When streaming options is set, the last chunk contains usage information
    public var usage: Usage?

    public init(
        id: String,
        object: String,
        created: Date,
        model: String,
        systemFingerprint: String? = nil,
        choices: [Choice],
        usage: Usage? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.systemFingerprint = systemFingerprint
        self.choices = choices
        self.usage = usage
    }
}

public struct ToolCallDelta: Codable {
    public var index: Int?
    public var id: String?
    public var type: String?
    public var function: FunctionCallDelta?
}

public struct FunctionCallDelta: Codable {
    public var name: String?
    public var arguments: String?
}
