//
//  ServerHistoryAPI.swift
//  SwiftAgents
//
//  Internal protocol the Agents runner uses to dispatch a turn against any
//  API that stores conversation state server-side and chains via
//  `previous_response_id`. `OpenAI` conforms; `LMStudio` (an `OpenAI`
//  subclass that talks to LM Studio's OpenAI-compat `/v1/responses`)
//  picks up the conformance automatically. The runner branches on
//  `api.statePolicy.supportsServerSideHistory` to decide which dispatch
//  path to take, and on `api.statePolicy.responseIdsAreOpenAIRoutable` to
//  decide which span shape to emit.

import Foundation

package protocol ServerHistoryAPI: API {
    /// Make a single stateful turn against this provider. Mirrors
    /// `OpenAI.createResponse` but trimmed to the parameter set the Agents
    /// runner cares about. Sampling / metadata knobs are passed via
    /// `modelSettings`.
    func dispatchCreateResponse(
        input: Response.Input,
        model: String,
        instructions: String?,
        previousResponseId: String?,
        conversationId: String?,
        textFormat: TextFormat?,
        tools: [Tool]?,
        modelSettings: ModelSettings
    ) async throws -> Response
}

// `OpenAI` satisfies the requirement with `dispatchCreateResponse` declared on
// the class body (see `OpenAI.swift`) rather than here, so subclasses such as
// `OpenAIResponsesWebSocket` can override it. `LMStudio` inherits the HTTP
// implementation unchanged.
extension OpenAI: ServerHistoryAPI {}
