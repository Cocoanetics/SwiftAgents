//
//  LocalFunction.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 13.04.24.
//

import Foundation

public struct LocalFunction
{
	var name: String
	var description: String
	
	var parameters: [Parameter]
	
	var block: ([String: Any]) async throws -> (String)
	
	public init(name: String, description: String, parameters: [Parameter] = [], block: @escaping ([String: Any]) async throws -> (String))
	{
		self.name = name
		self.description = description
		self.parameters = parameters
		self.block = block
	}
}
