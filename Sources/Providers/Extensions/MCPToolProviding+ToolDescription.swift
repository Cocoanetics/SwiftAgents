import Foundation
import SwiftMCP

public extension MCPToolProviding {
    /**
     Converts the MCPToolMetadata into an array of ToolDescription.
     - Returns: An array of ToolDescription.

     `async` because `mcpToolMetadata` is an async protocol requirement on
     `MCPToolProviding` (actor-backed conformers keep it isolated; concrete
     `@MCPServer` hosts satisfy it with a `nonisolated` getter, so they incur
     no real suspension).
     */
    var toolDescriptions: [ToolDescription] {
        get async {
            let metadata = await mcpToolMetadata
            return metadata.map { meta in
                // Create properties for the JSON schema
                let properties = Dictionary(uniqueKeysWithValues: meta.parameters.map { param in
                    (param.name, param.schema)
                })

                // Determine which parameters are required using the isRequired property
                let required = meta.parameters.filter(\.isRequired).map(\.name)

                let parameters = Parameters(properties: properties, required: required)

                let functionDescription = FunctionDescription(
                    name: meta.name,
                    description: meta.description,
                    parameters: parameters
                )
                return ToolDescription(type: "function", function: functionDescription)
            }
        }
    }
}

public extension [MCPToolProviding] {
    /// Gathers `toolDescriptions` from every provider in the array.
    ///
    /// `async` because each provider's `mcpToolMetadata` is an async
    /// requirement; this replaces the former `flatMap(\.toolDescriptions)`
    /// call sites, which cannot form a key path to an async member.
    var toolDescriptions: [ToolDescription] {
        get async {
            var all: [ToolDescription] = []
            for provider in self {
                all += await provider.toolDescriptions
            }
            return all
        }
    }
}
