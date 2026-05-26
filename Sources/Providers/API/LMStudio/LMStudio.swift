//
//  LMStudio.swift
//  SwiftAgents
//
//  LM Studio provider. Talks to LM Studio's native stateful chat endpoint at
//  `/api/v1/chat` rather than the OpenAI-compat layer at `/v1/chat/completions`.
//  The native endpoint keeps conversation state server-side and accepts a
//  `previous_response_id` to chain turns, so the Runner never needs to resend
//  history. Spans are emitted as `GenerationSpanData` because LM Studio's
//  response ids are not resolvable by OpenAI's trace dashboard.
//
//  Configuration:
//    - `LMSTUDIO_URL` — base URL of the LM Studio REST server.
//      Default `http://localhost:1234`.
//    - `LM_API_TOKEN` — optional bearer token. LM Studio doesn't require auth
//      out of the box but supports it when configured.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension URL {
    /// Default endpoint URL for the LM Studio REST server.
    static let lmStudio = URL(string: "http://localhost:1234")!
}

/// LM Studio API client. The Agents runner dispatches to `createResponse`
/// (mirroring `OpenAI.createResponse`'s signature) which under the hood
/// posts to `/api/v1/chat` with `previous_response_id` chaining.
public class LMStudio: API, @unchecked Sendable {
    /// LM Studio is stateful (chains via `previous_response_id`) but its ids
    /// are not OpenAI-routable, so spans are emitted as `GenerationSpanData`
    /// rather than `ResponseSpanData`.
    override open var statePolicy: ConversationStatePolicy { .lmStudioNative }

    public init(
        apiKey: String? = nil,
        endpointURL: URL = .lmStudio
    ) {
        // versionPath is unused for the native endpoint (which is hardcoded
        // to /api/v1/chat) but base APIs like `models()` still rely on it.
        // LM Studio exposes the OpenAI-compat /v1/models so we keep "v1".
        super.init(
            apiKey: apiKey ?? ProcessInfo.processInfo.environment["LM_API_TOKEN"],
            endpointURL: endpointURL,
            versionPath: "v1"
        )
    }
}
