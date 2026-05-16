//
//  ArgFunctionDescription.swift
//
//
//  Created by Oliver Drobnik on 23.04.24.
//

import Foundation

public struct ArgFunctionDescription: Encodable {
	public var function: String
	public var description: String
	public var arguments: [Argument]
}

public struct Argument: Encodable {
	public var name: String
	public var type: String
	public var description: String
}
