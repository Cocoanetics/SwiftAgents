//
//  FunctionDescription+JSON.swift
//  AgentCorp
//
//  Created by Oliver Drobnik on 20.05.25.
//

import Foundation

extension Array where Element == FunctionDescription
{
	// creates a JSON representation for use when injecting it into the system prompt
	public func asJSON() -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted]
		let data = try! encoder.encode(self)
		let string = String(data: data, encoding: .utf8)!
		return string
	}
}
