//
//  MCPRequireApproval.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 22.05.25.
//

import Foundation

/// An MCP tool configuration for remote tool servers.
public enum MCPRequireApproval: Codable, Sendable, Equatable {
	case never
	case always
	case neverFilter([String])
	case alwaysFilter([String])

	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let str = try? container.decode(String.self) {
			switch str {
			case "never": self = .never
			case "always": self = .always
			default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown string for require_approval")
			}
			return
		}
		if let dict = try? container.decode([String: MCPApprovalFilter].self) {
			if let filter = dict["never"] { self = .neverFilter(filter.toolNames ?? []); return }
			if let filter = dict["always"] { self = .alwaysFilter(filter.toolNames ?? []); return }
		}
		throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown require_approval format")
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .never:
			try container.encode("never")
		case .always:
			try container.encode("always")
		case .neverFilter(let names):
			try container.encode(["never": MCPApprovalFilter(toolNames: names)])
		case .alwaysFilter(let names):
			try container.encode(["always": MCPApprovalFilter(toolNames: names)])
		}
	}

	public static func == (lhs: MCPRequireApproval, rhs: MCPRequireApproval) -> Bool {
		switch (lhs, rhs) {
		case (.never, .never): return true
		case (.always, .always): return true
		case let (.neverFilter(la), .neverFilter(ra)): return la == ra
		case let (.alwaysFilter(la), .alwaysFilter(ra)): return la == ra
		default: return false
		}
	}
}
