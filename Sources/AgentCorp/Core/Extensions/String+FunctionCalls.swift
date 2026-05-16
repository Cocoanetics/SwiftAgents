//
//  String+FunctionCalls.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 12.04.24.
//

import Foundation

// Extend the String class to add functionality for extracting function calls.
extension String {
	/// Extracts function calls from a JSON-formatted string embedded within the calling String instance.
	/// Before extraction, strips out any inline comments that follow the '//' pattern, which are not part of the official JSON specification.
	/// Utilizes a regular expression to identify and isolate valid JSON objects that represent function calls.
	/// Each JSON object is expected to contain a "function" key with a string value and an "arguments" key with a JSON-formatted string value.
	///
	/// - Returns: An array of `FunctionCall` structs, each representing a function call with its name and JSON-formatted arguments string.
	/// - Throws: This method can throw errors related to regular expression failures or JSON parsing issues, which are caught internally and logged.
	func extractFunctionCalls() -> [FunctionCall]? {
		let functionCalls: [FunctionCall] = self.containedJsonStrings().compactMap { string in
			
			guard let jsonData = string.data(using: .utf8),
				  let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) else {
				return nil
			}
			
			var function: String?
			var arguments = [String: Any]()
			
			if let dict = jsonObject as? [String: Any] {
				for key in dict.keys {
					let value = dict[key]
					
					if let string = value as? String {
						if ["tool", "function"].contains(key) {
							// that's the function name
							function = string
							continue
						}
					} else if let dict = value as? [String: Any] {
						// copy all the values
						for (innerKey, innerValue) in dict {
							if ["tool_input", "parameters", "arguments"].contains(innerKey) {
								// handle nested dictionaries
								if let nestedDict = innerValue as? [String: Any] {
									for (nestedKey, nestedValue) in nestedDict {
										arguments[nestedKey] = nestedValue
									}
								}
							} else {
								arguments[innerKey] = innerValue
							}
						}
						continue
					} else if let array = value as? [[String: Any]] {
						for dict in array {
							if let name = dict["name"] as? String, let value = dict["value"] {
								// treat as argument value
								arguments[name] = value
							} else {
								// copy all the values
								for (key, value) in dict {
									arguments[key] = value
								}
							}
						}
						continue
					}
					
					// treat as argument value
					arguments[key] = value
				}
			}
			
			if let function = function {
				guard let argumentsData = try? JSONSerialization.data(withJSONObject: arguments, options: []),
					  let argumentsString = String(data: argumentsData, encoding: .utf8) else {
					return nil
				}
				return FunctionCall(name: function, arguments: argumentsString)
			}
			
			return nil
		}
		
		guard !functionCalls.isEmpty else {
			return nil
		}
		
		return functionCalls
	}

	
	/*
	 
	 let jsonData = string.data(using: .utf8)!
	 
	 guard let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) else {
		 return nil
	 }
	 
	 guard let jsonDict = jsonObject as? [String: Any] else
	 {
		 return nil
	 }
	 
	 if let tool = jsonDict["tool"] as? String
	 {
		 if let toolInput = jsonDict["tool_input"] as? [String: String],
			let argumentsData = try? JSONSerialization.data(withJSONObject: toolInput, options: [])
		 {
			 let argumentsString = String(data: argumentsData, encoding: .utf8) ?? ""
			 return FunctionCall(name: tool, arguments: argumentsString)
		 }
		 else if let argumentsArray = jsonDict["arguments"] as? [[String: Any]]
		 {
			 var mergedArguments = [String: Codable]()
			 
			 for dictionary in argumentsArray
			 {
				 if let name = dictionary["name"] as? String, let value = dictionary["value"]
				 {
					 mergedArguments[name] = value
				 }
				 else
				 {
					 for key in dictionary.keys
					 {
						 mergedArguments[key] = dictionary[key]
					 }
				 }
			 }
			 
			 let argumentsData = try! JSONSerialization.data(withJSONObject: mergedArguments, options: [])
			 let argumentsString = String(data: argumentsData, encoding: .utf8) ?? ""
			 return FunctionCall(name: tool, arguments: argumentsString)
		 }
		 else
		 {
			 var arguments = [String: Any]()
			 
			 for (key, value) in jsonDict
			 {
				 guard key != "tool" else
				 {
					 continue
				 }
				 
				 arguments[key] = value
			 }
			 
			 if	let argumentsData = try? JSONSerialization.data(withJSONObject: arguments, options: [])
			 {
				 let argumentsString = String(data: argumentsData, encoding: .utf8) ?? ""
				 return FunctionCall(name: tool, arguments: argumentsString)
			 }
		 }
	 }
	 
	 if let function = jsonDict["function"] as? String {
		 var arguments: [String: String] = [:]
		 
		 for (key, value) in jsonDict where key != "function" {
			 if let stringValue = value as? String {
				 arguments[key] = stringValue
			 }
		 }
		 
		 if !arguments.isEmpty {
			 guard let argumentsData = try? JSONSerialization.data(withJSONObject: arguments, options: []) else {
				 return nil
			 }
			 
			 let argumentsString = String(data: argumentsData, encoding: .utf8) ?? ""
			 return FunctionCall(name: function, arguments: argumentsString)
		 }
		 
		 let argsOrParams = jsonDict["arguments"] ?? jsonDict["parameters"] ?? jsonDict["data"]
		 
		 if let argumentsDict = argsOrParams as? [String: String] {
			 guard let argumentsData = try? JSONSerialization.data(withJSONObject: argumentsDict, options: []) else {
				 return nil
			 }
			 
			 let argumentsString = String(data: argumentsData, encoding: .utf8) ?? ""
			 return FunctionCall(name: function, arguments: argumentsString)
		 }
		 
		 if let argumentsArray = argsOrParams as? [[String: Any]]
		 {
			 var mergedArguments = [String: String]()
			 
			 for dictionary in argumentsArray {
				 if let name = dictionary["name"] as? String, let value = dictionary["value"] as? String
				 {
					 // Case where each dictionary has "name" and "value"
					 mergedArguments[name] = value
				 } else {
					 // Case where dictionary directly contains param_name: param_value
					 for (key, value) in dictionary {
						 if let stringValue = value as? String {
							 mergedArguments[key] = stringValue
						 }
					 }
				 }
			 }
			 
			 guard let argumentsData = try? JSONSerialization.data(withJSONObject: mergedArguments, options: []) else {
				 return nil
			 }
			 
			 let argumentsString = String(data: argumentsData, encoding: .utf8) ?? ""
			 return FunctionCall(name: function, arguments: argumentsString)
		 }
	 }
	 
	 return nil
	 
	 */
	
	public func containedJsonStrings() -> [String]
	{
		var jsonObjects = [String]()
		var depth = 0
		var inString = false
		var escape = false
		var startIndex: String.Index?

		for (index, char) in self.enumerated()
		{
			switch char {
			case "\"":
				if !escape {
					inString.toggle() // Toggle the inString state if the quote is not escaped
				}
			case "{":
				if !inString {
					if depth == 0 {
						startIndex = self.index(self.startIndex, offsetBy: index)
					}
					depth += 1
				}
			case "}":
				if !inString {
					depth -= 1
					if depth == 0, let start = startIndex 
					{
						let endIndex = self.index(self.startIndex, offsetBy: index + 1)
						let jsonString = String(self[start..<endIndex])
						jsonObjects.append(jsonString)
						startIndex = nil
					}
				}
			default:
				break
			}
			
			// Handle escaping within strings
			escape = (char == "\\" && !escape && inString)
		}
		
		return jsonObjects
	}
}
