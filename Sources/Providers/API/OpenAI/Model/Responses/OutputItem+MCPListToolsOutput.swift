import Foundation
import SwiftMCP

public extension OutputItem {
    /// Represents the output for an MCP list tools response.
    struct MCPListToolsOutput: Codable, Sendable {
        /// The unique ID of this output item.
        public let id: String
        /// The server label (e.g., "deepwiki").
        public let serverLabel: String
        /// The list of tools available on the server.
        public let tools: [MCPListTool]
    }

    /// Represents a single tool in the MCP list tools output.
    struct MCPListTool: Codable, Sendable {
        public let name: String
        public let description: String?
        public let inputSchema: [String: JSONValue]
        public let annotations: [String: JSONValue]?

        private enum CodingKeys: String, CodingKey {
            case name
            case description
            case inputSchema = "input_schema"
            case annotations
        }
    }
}
