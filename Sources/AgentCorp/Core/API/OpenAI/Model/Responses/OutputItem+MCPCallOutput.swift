import Foundation

extension OutputItem {
    /// Represents the output for an MCP call response.
    public struct MCPCallOutput: Codable, Sendable {
        public let id: String
        public let approvalRequestId: String?
        public let arguments: String?
        public let error: String?
        public let name: String?
        public let output: String?
        public let serverLabel: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case approvalRequestId = "approval_request_id"
            case arguments
            case error
            case name
            case output
            case serverLabel = "server_label"
        }
    }
} 