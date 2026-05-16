//
//  Tool.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 24.04.25.
//

import Foundation
import SwiftMCP

/// Represents a tool that can be used by the model.
public enum Tool: Codable, Sendable {
    /// A function tool that can be called by the model.
    case function(FunctionTool)

    /// A file search tool.
    case fileSearch(FileSearchTool)

    /// A web search tool.
    case webSearch(WebSearchTool)

    /// A computer use tool.
    case computer(ComputerTool)

    /// An MCP tool (Model Context Protocol remote tool server)
    case mcp(MCPRemoteTool)

    /// An apply_patch tool for creating, updating, and deleting files via V4A diffs.
    case applyPatch

    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case description
        case parameters
        case displayHeight = "display_height"
        case displayWidth = "display_width"
        case environment
        case searchContextSize = "search_context_size"
        case userLocation = "user_location"
        case vectorStoreIds = "vector_store_ids"
        case serverLabel = "server_label"
        case serverURL = "server_url"
        case requireApproval = "require_approval"
        case allowedTools = "allowed_tools"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
            case let .function(tool):
                try container.encode("function", forKey: .type)
                try container.encode(tool.name, forKey: .name)
                if let description = tool.description {
                    try container.encode(description, forKey: .description)
                }
                try container.encode(tool.parameters, forKey: .parameters)
            case let .fileSearch(tool):
                try container.encode("file_search", forKey: .type)
                try container.encode(tool.vectorStoreIds, forKey: .vectorStoreIds)
            case let .webSearch(tool):
                try container.encode(tool.type, forKey: .type)
                if let contextSize = tool.searchContextSize {
                    try container.encode(contextSize, forKey: .searchContextSize)
                }
                if let location = tool.userLocation {
                    try container.encode(location, forKey: .userLocation)
                }
            case let .computer(tool):
                try container.encode("computer_use_preview", forKey: .type)
                try container.encode(tool.displayHeight, forKey: .displayHeight)
                try container.encode(tool.displayWidth, forKey: .displayWidth)
                try container.encode(tool.environment, forKey: .environment)
            case let .mcp(tool):
                try container.encode("mcp", forKey: .type)
                try container.encode(tool.serverLabel, forKey: .serverLabel)
                try container.encode(tool.serverURL, forKey: .serverURL)
                try container.encodeIfPresent(tool.requireApproval, forKey: .requireApproval)
                try container.encodeIfPresent(tool.allowedTools, forKey: .allowedTools)
            case .applyPatch:
                try container.encode("apply_patch", forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
            case "function":
                let name = try container.decode(String.self, forKey: .name)
                let description = try container.decodeIfPresent(String.self, forKey: .description)
                let parameters = try container.decode(Parameters.self, forKey: .parameters)
                self = .function(FunctionTool(
                    name: name,
                    description: description,
                    parameters: parameters,
                    strict: false
                ))
            case "file_search":
                let vectorStoreIds = try container.decode([String].self, forKey: .vectorStoreIds)
                self = .fileSearch(FileSearchTool(vectorStoreIds: vectorStoreIds))
            case "web_search_preview", "web_search_preview_2025_03_11":
                let contextSize = try container.decodeIfPresent(String.self, forKey: .searchContextSize)
                let location = try container.decodeIfPresent(UserLocation.self, forKey: .userLocation)
                self = .webSearch(WebSearchTool(type: type, searchContextSize: contextSize, userLocation: location))
            case "computer_use_preview":
                let height = try container.decode(Double.self, forKey: .displayHeight)
                let width = try container.decode(Double.self, forKey: .displayWidth)
                let env = try container.decode(String.self, forKey: .environment)
                self = .computer(ComputerTool(displayHeight: height, displayWidth: width, environment: env))
            case "mcp":
                let serverLabel = try container.decode(String.self, forKey: .serverLabel)
                let serverURL = try container.decode(URL.self, forKey: .serverURL)
                let requireApproval = try container.decodeIfPresent(MCPRequireApproval.self, forKey: .requireApproval)
                let allowedTools = try container.decodeIfPresent(MCPAllowedTools.self, forKey: .allowedTools)
                self = .mcp(MCPRemoteTool(
                    serverLabel: serverLabel,
                    serverURL: serverURL,
                    requireApproval: requireApproval,
                    allowedTools: allowedTools
                ))
            case "apply_patch":
                self = .applyPatch
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown tool type: \(type)"
                )
        }
    }
}
