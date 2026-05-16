//
//  Parameter.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 13.04.24.
//

import Foundation

public struct Parameter
{
	public var name: String
	public var description: String?
	public var type: Any.Type
	public var `enum`: [CustomStringConvertible]?
	
	public init(name: String, description: String? = nil, type: Any.Type, enum: [CustomStringConvertible]? = nil)
	{
		self.name = name
		self.description = description
		self.type = type
		self.enum = `enum`
	}
}
