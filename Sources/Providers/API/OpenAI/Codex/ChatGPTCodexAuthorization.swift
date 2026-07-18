//
//  ChatGPTCodexAuthorization.swift
//  SwiftAgents
//
//  Authorization for the ChatGPT Codex backend
//  (chatgpt.com/backend-api/codex): a ChatGPT-subscription OAuth access
//  token plus the routing/telemetry headers the backend expects from a
//  Codex client — mirroring the codex CLI's wire protocol. Applied to
//  every request through the standard `RequestAuthorizing` seam.
//

import Foundation
import SwiftCross

/// Authorizes requests against the ChatGPT Codex backend with a
/// subscription OAuth access token (instead of an OpenAI API key).
public struct ChatGPTCodexAuthorization: RequestAuthorizing, Sendable {
    /// The ChatGPT OAuth access token, sent as `Authorization: Bearer …`.
    public let accessToken: String

    /// The ChatGPT account to route this traffic to (`ChatGPT-Account-ID`
    /// header). Optional — omitted when nil or empty.
    public let accountID: String?

    /// Identifies this client session (`session-id` header).
    public let sessionID: UUID

    /// Identifies the conversation thread (`thread-id` and
    /// `x-client-request-id` headers).
    public let threadID: UUID

    public init(
        accessToken: String,
        accountID: String?,
        sessionID: UUID = UUID(),
        threadID: UUID = UUID()
    ) {
        self.accessToken = accessToken
        self.accountID = accountID
        self.sessionID = sessionID
        self.threadID = threadID
    }

    public func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        // The backend expects a known client originator + matching UA.
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("codex_cli_rs/0.0.0 (SwiftAgents; macOS)", forHTTPHeaderField: "User-Agent")

        request.setValue(sessionID.uuidString.lowercased(), forHTTPHeaderField: "session-id")
        request.setValue(threadID.uuidString.lowercased(), forHTTPHeaderField: "thread-id")
        request.setValue(threadID.uuidString.lowercased(), forHTTPHeaderField: "x-client-request-id")
    }
}
