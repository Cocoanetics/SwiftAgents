//
//  ToolChoiceDescription.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 20.05.25.
//

import Foundation

public struct ToolChoiceDescription: Codable, Sendable
{
	public var type: String?
	public var function: Function?
	
	public struct Function: Codable, Sendable
	{
		public var name: String?
	}
}
