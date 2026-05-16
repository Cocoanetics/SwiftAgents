import Foundation
import SwiftMCP

extension MCPToolProviding {
	/**
	 Converts the MCPToolMetadata into an array of ToolDescription.
	 - Returns: An array of ToolDescription.
	 */
	public var toolDescriptions: [ToolDescription] {
		
		return mcpToolMetadata.map { meta in
			// Create properties for the JSON schema
			let properties = Dictionary(uniqueKeysWithValues: meta.parameters.map { param in
				return (param.name, param.schema)
			})
			
			// Determine which parameters are required using the isRequired property
			let required = meta.parameters.filter { $0.isRequired }.map { $0.name }
			
			let parameters = Parameters(properties: properties, required: required)
			
			let functionDescription = FunctionDescription(name: meta.name, description: meta.description, parameters: parameters)
			return ToolDescription(type: "function", function: functionDescription)
		}
    }
} 
