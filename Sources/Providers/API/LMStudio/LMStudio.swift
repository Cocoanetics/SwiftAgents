//
//  LMStudio.swift
//  SwiftAgents
//
//  LM Studio provider. LM Studio implements the OpenAI-compat surface
//  natively — both `/v1/chat/completions` and `/v1/responses` accept the
//  standard OpenAI shapes (tools, structured output, image_url content,
//  `previous_response_id` chaining, etc.). The only thing that
//  distinguishes LM Studio from OpenAI at the Runner / tracing layer is
//  that its response ids are NOT routable to OpenAI's trace dashboard —
//  we emit `GenerationSpanData` instead of `ResponseSpanData` so the
//  payload is self-contained.
//
//  Configuration:
//    - `LMSTUDIO_URL` — base URL of the LM Studio REST server.
//      Default `http://localhost:1234`.
//    - `LM_API_TOKEN` — optional bearer token. LM Studio doesn't require
//      auth out of the box but supports it when configured.

import Foundation
import Tracing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension URL {
    /// Default endpoint URL for the LM Studio REST server.
    static let lmStudio = URL(string: "http://localhost:1234")!
}

/// LM Studio API client — a thin `OpenAI` subclass that targets the
/// LM Studio server's OpenAI-compat endpoints. All of
/// `createResponse` / `createChatCompletion` / streaming / Conversations
/// inherit from `OpenAI` and work out of the box because LM Studio
/// speaks the OpenAI wire on `/v1/responses` and `/v1/chat/completions`.
public class LMStudio: OpenAI, @unchecked Sendable {
    /// LM Studio's response ids are not resolvable by OpenAI's trace
    /// dashboard; everything else (server-side history, structured
    /// output, tool calls, image input) matches OpenAI exactly.
    override open var statePolicy: ConversationStatePolicy { .lmStudioOpenAICompat }

    /// LM Studio's `/v1/responses` supports SSE streaming, so opt into the
    /// Responses streaming path (the inherited default only matches first-party
    /// `api.openai.com`). Structured-output turns still fall back to
    /// chat-completion streaming via the Runner, because LM Studio's Responses
    /// endpoint ignores `text.format.json_schema` (see `.lmStudioOpenAICompat`).
    override open var prefersResponsesStreaming: Bool { true }

    public init(
        credential: (any RequestAuthorizing)? = nil,
        endpointURL: URL = .lmStudio
    ) {
        super.init(
            credential: credential ?? ProcessInfo.processInfo.environment["LM_API_TOKEN"].map(Credential.bearer),
            endpointURL: endpointURL,
            versionPath: "v1"
        )
    }
}
