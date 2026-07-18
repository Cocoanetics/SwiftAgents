//
//  ChatGPTCodex.swift
//  SwiftAgents
//
//  Responses client for the ChatGPT-subscription Codex backend
//  (https://chatgpt.com/backend-api/codex). Same wire shape as the
//  first-party Responses API, with three differences this subclass carries:
//
//  - paths have no `/v1` prefix (`…/codex/responses`, `…/codex/models`),
//  - no `OpenAI-Beta` header on HTTP requests,
//  - nothing is persisted server-side (`store` is forced false by the
//    backend), so the state policy disables `previous_response_id`
//    chaining and the streamed Runner resends the full accumulated
//    conversation every turn.
//

import Foundation
import SwiftCross

public final class ChatGPTCodex: OpenAI, @unchecked Sendable {
    /// Stateless Responses backend: full input every turn, ids not routable
    /// to OpenAI tracing.
    override public var statePolicy: ConversationStatePolicy { .chatGPTCodex }

    /// The codex backend has no chat-completions surface — Responses
    /// streaming is the only path. (The `OpenAI` default is endpoint-gated
    /// to api.openai.com; this is the subclass its doc comment anticipates.)
    override public var prefersResponsesStreaming: Bool { true }

    public init(authorization: ChatGPTCodexAuthorization) {
        super.init(
            credential: authorization,
            endpointURL: URL(string: "https://chatgpt.com/backend-api/codex")!
        )
    }

    override public func createUrlRequest(
        httpMethod: String = "GET",
        path: String,
        body: Codable? = nil,
        queryItems: [URLQueryItem]? = nil
    ) throws -> URLRequest {
        // The shared endpoints hardcode "/v1/…" paths; the codex backend
        // mounts the same resources directly under its base URL
        // (…/backend-api/codex/responses), so strip the version prefix.
        var path = path
        if path.hasPrefix("/v1/") {
            path.removeFirst("/v1".count)
        }

        var request = try super.createUrlRequest(
            httpMethod: httpMethod,
            path: path,
            body: body,
            queryItems: queryItems
        )

        // codex sends no OpenAI-Beta header on HTTP requests — drop the
        // `assistants=v2` value the OpenAI superclass stamps.
        request.setValue(nil, forHTTPHeaderField: "OpenAI-Beta")

        return request
    }
}
