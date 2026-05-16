//
//  MCPApprovalFilter.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 22.05.25.
//

import Foundation

public struct MCPApprovalFilter: Codable, Equatable, Sendable {
	public let toolNames: [String]?
	enum CodingKeys: String, CodingKey {
		case toolNames = "tool_names"
	}
	public init(toolNames: [String]?) {
		self.toolNames = toolNames
	}
}
