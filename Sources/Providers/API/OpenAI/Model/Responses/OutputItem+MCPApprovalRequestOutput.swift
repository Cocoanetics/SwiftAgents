import Foundation

public extension OutputItem {
    /// Represents the output for an MCP approval request.
    struct MCPApprovalRequestOutput: Codable, Sendable {
        /// The unique ID of this output item.
        public let id: String
        /// The name of the tool being called.
        public let name: String
        /// The server label (e.g., "deepwiki").
        public let serverLabel: String
        /// The arguments for the tool call, as a JSON string.
        public let arguments: String
    }
}
