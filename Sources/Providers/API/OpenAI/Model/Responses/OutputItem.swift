//
//  OutputItem.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 24.04.25.
//

import Foundation

/// Represents an output item from the model.
public enum OutputItem: Codable, Sendable {
	/// An output message from the model.
	case message(MessageOutput)

	/// A file search tool call result.
	case fileSearch(FileSearchOutput)

	/// A function tool call.
	case functionCall(FunctionCall)

	/// A web search tool call result.
	case webSearch(WebSearchOutput)

	/// A computer tool call.
	case computer(ComputerOutput)

	/// A description of the chain of thought used by a reasoning model.
	case reasoning(ReasoningOutput)

	/// An MCP list tools output.
	case mcpListTools(MCPListToolsOutput)

	/// An MCP approval request output.
	case mcpApprovalRequest(MCPApprovalRequestOutput)

	/// An MCP call output.
	case mcpCall(MCPCallOutput)

	/// An apply_patch tool call.
	case applyPatchCall(ApplyPatchCallOutput)

	// MARK: - Codable

	private enum CodingKeys: String, CodingKey {
		case type
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let type = try container.decode(String.self, forKey: .type)

		switch type {
			case "message":
				self = .message(try MessageOutput(from: decoder))
			case "file_search_call":
				self = .fileSearch(try FileSearchOutput(from: decoder))
			case "function_call":
				self = .functionCall(try FunctionCall(from: decoder))
			case "web_search_call":
				self = .webSearch(try WebSearchOutput(from: decoder))
			case "computer_call":
				self = .computer(try ComputerOutput(from: decoder))
			case "reasoning":
				self = .reasoning(try ReasoningOutput(from: decoder))
			case "mcp_list_tools":
				self = .mcpListTools(try MCPListToolsOutput(from: decoder))
			case "mcp_approval_request":
				self = .mcpApprovalRequest(try MCPApprovalRequestOutput(from: decoder))
			case "mcp_call":
				self = .mcpCall(try MCPCallOutput(from: decoder))
			case "apply_patch_call":
				self = .applyPatchCall(try ApplyPatchCallOutput(from: decoder))
			default:
				throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown output type: \(type)")
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)

		switch self {
			case .message(let output):
				try container.encode("message", forKey: .type)
				try output.encode(to: encoder)
			case .fileSearch(let output):
				try container.encode("file_search_call", forKey: .type)
				try output.encode(to: encoder)
			case .functionCall(let output):
				try container.encode("function_call", forKey: .type)
				try output.encode(to: encoder)
			case .webSearch(let output):
				try container.encode("web_search_call", forKey: .type)
				try output.encode(to: encoder)
			case .computer(let output):
				try container.encode("computer_call", forKey: .type)
				try output.encode(to: encoder)
			case .reasoning(let output):
				try container.encode("reasoning", forKey: .type)
				try output.encode(to: encoder)
			case .mcpListTools(let output):
				try container.encode("mcp_list_tools", forKey: .type)
				try output.encode(to: encoder)
			case .mcpApprovalRequest(let output):
				try container.encode("mcp_approval_request", forKey: .type)
				try output.encode(to: encoder)
			case .mcpCall(let output):
				try container.encode("mcp_call", forKey: .type)
				try output.encode(to: encoder)
			case .applyPatchCall(let output):
				try container.encode("apply_patch_call", forKey: .type)
				try output.encode(to: encoder)
		}
	}
}
