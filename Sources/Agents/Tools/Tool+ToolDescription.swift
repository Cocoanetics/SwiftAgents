import Providers
//
//  Tool+ToolDescription.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 20.05.25.
//

public extension [Tool] {
    /// Converts an array of Tool to ToolDescription for use with ChatCompletions
    var toolDescriptions: [ToolDescription] {
        map { tool -> ToolDescription in
            switch tool {
                case let .function(functionTool):
                    return ToolDescription(type: "function", function: FunctionDescription(
                        name: functionTool.name,
                        description: functionTool.description,
                        parameters: functionTool.parameters
                    ))
                case .fileSearch:
                    return ToolDescription(type: "file_search")
                case .webSearch:
                    return ToolDescription(type: "web_search")
                case .computer:
                    return ToolDescription(type: "computer_use_preview")
                case .mcp:
                    preconditionFailure("MCP Tools not supported")
                case .applyPatch:
                    return ToolDescription(type: "apply_patch")
                case .imageGeneration:
                    // The image_generation built-in tool is Responses-only;
                    // chat completions can't carry it. Emit the bare type so
                    // the conversion stays total — the Responses path sends the
                    // full `Tool` value, so this stub is never the live wire.
                    return ToolDescription(type: "image_generation")
            }
        }
    }
}
