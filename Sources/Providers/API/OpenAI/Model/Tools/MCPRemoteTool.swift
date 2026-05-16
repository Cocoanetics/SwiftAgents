import Foundation
import SwiftMCP

public struct MCPRemoteTool: Codable, Sendable, Equatable {
    public let serverLabel: String
    public let serverURL: URL
    public let requireApproval: MCPRequireApproval?
    public let allowedTools: MCPAllowedTools?
    public init(serverLabel: String, serverURL: URL, requireApproval: MCPRequireApproval? = nil, allowedTools: MCPAllowedTools? = nil) {
        self.serverLabel = serverLabel
        self.serverURL = serverURL
        self.requireApproval = requireApproval
        self.allowedTools = allowedTools
    }
}
