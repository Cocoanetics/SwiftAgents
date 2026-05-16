//
//  Scanner+LocalFunction.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 13.04.24.
//

import Foundation

extension Scanner
{
	func scanOptional() -> Bool
	{
		if scanString("Optional<") != nil
		{
			return true
		}
		
		return false
	}
	
	func scanArray() -> Bool
	{
		if scanString("Array<") != nil
		{
			return true
		}
		
		return false
	}
	
	func scanType() -> String?
	{
		let pos = self.currentIndex
		
		if let type = scanUpToString(">")
		{
			switch type
			{
				case "String":
					return "string"
					
				case "Int", "Double", "Float", "Int64":
					return "number"
					
				case "Bool":
					return "boolean"
					
				case "Date":
					return "number"
					
				default:
					
					self.currentIndex = pos
					return nil
			}
		}
		
		return nil
	}
}
