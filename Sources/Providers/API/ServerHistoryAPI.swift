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

protocol ServerHistoryAPI: API {
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

extension OpenAI: ServerHistoryAPI {
    func dispatchCreateResponse(
        input: Response.Input,
        model: String,
        instructions: String?,
        previousResponseId: String?,
        conversationId: String?,
        textFormat: TextFormat?,
        tools: [Tool]?,
        modelSettings: ModelSettings
    ) async throws -> Response {
        try await createResponse(
            input: input,
            model: model,
            conversation: conversationId,
            instructions: instructions,
            maxOutputTokens: modelSettings.maxCompletionTokens,
            metadata: modelSettings.metadata,
            parallelToolCalls: modelSettings.parallelToolCalls,
            previousResponseId: previousResponseId,
            reasoning: modelSettings.reasoning,
            store: modelSettings.store,
            temperature: modelSettings.temperature,
            textFormat: textFormat,
            toolChoice: modelSettings.toolChoice,
            tools: tools,
            topP: modelSettings.topP,
            truncation: modelSettings.truncation
        )
    }
}
