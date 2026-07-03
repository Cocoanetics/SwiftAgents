//
//  AnthropicTool.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.05.26.
//

import Foundation
import JSONFoundation

/// Function-like tool declaration for the Anthropic Messages API.
///
/// Anthropic calls the JSON-schema field `input_schema` (vs. OpenAI's
/// `parameters`); everything else is the same.
public struct AnthropicTool: Codable, Sendable {
    public let name: String
    public let description: String?
    public let inputSchema: JSONSchema

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }

    public init(name: String, description: String?, inputSchema: JSONSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Controls whether/which tool the model is allowed to call.
public enum AnthropicToolChoice: Codable, Sendable {
    /// Default — model decides whether to call a tool.
    case auto(disableParallel: Bool?)

    /// Forces the model to call *some* tool.
    case any(disableParallel: Bool?)

    /// Forces the model to call this specific tool by name.
    case tool(name: String, disableParallel: Bool?)

    /// Prevents tool calls entirely.
    case none

    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case disableParallelToolUse = "disable_parallel_tool_use"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
            case let .auto(disableParallel):
                try container.encode("auto", forKey: .type)
                try container.encodeIfPresent(disableParallel, forKey: .disableParallelToolUse)
            case let .any(disableParallel):
                try container.encode("any", forKey: .type)
                try container.encodeIfPresent(disableParallel, forKey: .disableParallelToolUse)
            case let .tool(name, disableParallel):
                try container.encode("tool", forKey: .type)
                try container.encode(name, forKey: .name)
                try container.encodeIfPresent(disableParallel, forKey: .disableParallelToolUse)
            case .none:
                try container.encode("none", forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let disableParallel = try container.decodeIfPresent(Bool.self, forKey: .disableParallelToolUse)
        switch type {
            case "auto":
                self = .auto(disableParallel: disableParallel)
            case "any":
                self = .any(disableParallel: disableParallel)
            case "tool":
                let name = try container.decode(String.self, forKey: .name)
                self = .tool(name: name, disableParallel: disableParallel)
            case "none":
                self = .none
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown Anthropic tool_choice type: \(type)"
                )
        }
    }
}
