//
//  ToolDescription.swift
//  AgentCorp
//
//  Created by Oliver Drobnik on 20.05.25.
//

import Foundation

public struct ToolDescription: Codable, Sendable
{
	static let codeInterpreter = ToolDescription(type: "code_interpreter")
	static let fileSearch = ToolDescription(type: "file_search")
	
	public var type: String?
	public var function: FunctionDescription?
	
	public init(type: String? = nil, function: FunctionDescription? = nil) {
		self.type = type
		self.function = function
	}
}
