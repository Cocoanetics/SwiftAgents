//
//  MCPAllowedTools.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 22.05.25.
//

import Foundation
import SwiftMCP

/**
 Represents the allowed tools configuration for an MCP (Model Context Protocol) tool.

 This can be either a list of allowed tool names or a filter object specifying allowed tools.
*/
public enum MCPAllowedTools: Codable, Sendable, Equatable {
	/// Specifies allowed tools as a simple list of tool names.
	case list([String])

	/// Specifies allowed tools using a filter object with tool names.
	case filter([String])

	/**
	 Decodes the allowed tools from either an array of strings or a filter object.
	 - Parameter decoder: The decoder to read data from.
	 - Throws: An error if the data cannot be decoded as either a list or filter.
	 */
	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let arr = try? container.decode([String].self) {
			self = .list(arr)
			return
		}
		if let filter = try? container.decode(MCPAllowedToolsFilter.self) {
			self = .filter(filter.toolNames ?? [])
			return
		}
		throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown allowed_tools format")
	}

	/**
	 Encodes the allowed tools as either an array or a filter object, depending on the case.
	 - Parameter encoder: The encoder to write data to.
	 - Throws: An error if encoding fails.
	 */
	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
			case .list(let arr):
				try container.encode(arr)
			case .filter(let names):
				try container.encode(MCPAllowedToolsFilter(toolNames: names))
		}
	}

	// MARK: - Private Structs

	/**
	 Internal struct representing the filter object for allowed tools.
	 */
	fileprivate struct MCPAllowedToolsFilter: Codable, Sendable, Equatable {
		/// The list of allowed tool names.
		let toolNames: [String]?

		enum CodingKeys: String, CodingKey {
			case toolNames = "tool_names"
		}
	}
}
