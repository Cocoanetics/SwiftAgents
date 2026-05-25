//
//  Anthropic+Responses.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.05.26.
//
//  The OpenAI Responses API surface, backed by Anthropic's Messages API.
//  This is the entry point the Agents SDK runner uses.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension Anthropic {
    /// Mirrors `OpenAI.createResponse` so the Agents SDK runner can dispatch
    /// to Anthropic via the Responses-API shape. Internally converts the
    /// Response.Input to an Anthropic Messages request, calls Anthropic, and
    /// folds the result back into a `Response` value.
    ///
    /// Only parameters that have a meaningful Anthropic equivalent are
    /// forwarded. The rest are accepted for source-compatibility with
    /// `OpenAI.createResponse` but ignored.
    func createResponse(
        input: Response.Input,
        model: String,
        instructions: String? = nil,
        maxOutputTokens: Int? = nil,
        metadata: [String: String]? = nil,
        parallelToolCalls: Bool? = nil,
        previousResponseId: String? = nil,
        reasoning _: Reasoning? = nil,
        store _: Bool? = nil,
        temperature: Double? = nil,
        textFormat _: TextFormat? = nil,
        toolChoice: ToolChoice? = nil,
        tools: [Tool]? = nil,
        topP: Double? = nil,
        truncation _: Response.TruncationStrategy? = nil,
        user: String? = nil
    ) async throws -> Response {
        let (request, _) = try await buildRequest(
            input: input,
            model: model,
            instructions: instructions,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature,
            topP: topP,
            tools: tools,
            toolChoice: toolChoice,
            parallelToolCalls: parallelToolCalls,
            previousResponseId: previousResponseId,
            user: user,
            stream: false
        )
        _ = metadata // accepted for API compat; Anthropic only takes `user_id`.

        let anthropicResponse = try await createMessage(request)
        await cacheConversation(
            priorMessages: request.messages,
            assistantContent: anthropicResponse.content,
            responseId: anthropicResponse.id
        )
        return Anthropic.makeResponse(model: model, instructions: instructions, response: anthropicResponse)
    }

    /// Streaming variant of `createResponse`. Returns an async sequence of
    /// `ResponsesStreamEvent`s converted from Anthropic's SSE stream.
    func createResponseStream(
        input: Response.Input,
        model: String,
        instructions: String? = nil,
        maxOutputTokens: Int? = nil,
        metadata _: [String: String]? = nil,
        parallelToolCalls: Bool? = nil,
        previousResponseId: String? = nil,
        reasoning _: Reasoning? = nil,
        store _: Bool? = nil,
        temperature: Double? = nil,
        toolChoice: ToolChoice? = nil,
        tools: [Tool]? = nil,
        topP: Double? = nil,
        truncation _: Response.TruncationStrategy? = nil,
        user: String? = nil
    ) async throws -> AsyncThrowingStream<ResponsesStreamEvent, Error> {
        let (request, _) = try await buildRequest(
            input: input,
            model: model,
            instructions: instructions,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature,
            topP: topP,
            tools: tools,
            toolChoice: toolChoice,
            parallelToolCalls: parallelToolCalls,
            previousResponseId: previousResponseId,
            user: user,
            stream: true
        )

        let anthropicEvents = try await createMessageStream(request)
        return Anthropic.makeResponsesStream(
            from: anthropicEvents,
            model: model,
            instructions: instructions,
            cacheAssistantTurn: { [self] responseId, content in
                await cacheConversation(
                    priorMessages: request.messages,
                    assistantContent: content,
                    responseId: responseId
                )
            }
        )
    }

    // MARK: - Helpers

    /// Assembles an `AnthropicMessagesRequest` from Responses-API arguments,
    /// prepending the cached conversation history for `previousResponseId` so
    /// stateless Anthropic gets the full context the stateful OpenAI surface
    /// would have referenced by id.
    ///
    /// Returns the request plus the prior history slice (sans the new turn),
    /// so callers can store the updated history once the response is in.
    func buildRequest(
        input: Response.Input,
        model: String,
        instructions: String?,
        maxOutputTokens: Int?,
        temperature: Double?,
        topP: Double?,
        tools: [Tool]?,
        toolChoice: ToolChoice?,
        parallelToolCalls: Bool?,
        previousResponseId: String?,
        user: String?,
        stream: Bool
    ) async throws -> (AnthropicMessagesRequest, [AnthropicMessage]) {
        let (system, newMessages) = Anthropic.convertResponseInput(input, instructions: instructions)
        let priorMessages: [AnthropicMessage]
        if let previousResponseId,
            let cached = await conversationCache.messages(forResponseId: previousResponseId) {
            priorMessages = cached
        } else {
            priorMessages = []
        }
        let allMessages = priorMessages + newMessages

        let anthropicTools = Anthropic.convertTools(tools)

        var convertedToolChoice = Anthropic.convertToolChoice(toolChoice)
        if let parallelToolCalls, !parallelToolCalls {
            convertedToolChoice = Anthropic.disableParallel(on: convertedToolChoice ?? .auto(disableParallel: nil))
        }

        let request = AnthropicMessagesRequest(
            model: model,
            messages: allMessages,
            maxTokens: maxOutputTokens ?? defaultMaxTokens,
            system: system,
            temperature: temperature,
            topP: topP,
            topK: nil,
            stopSequences: nil,
            stream: stream,
            tools: anthropicTools,
            toolChoice: convertedToolChoice,
            metadata: user.map { AnthropicMessagesRequest.Metadata(userId: $0) }
        )

        return (request, priorMessages)
    }
}

extension Anthropic {
    /// Returns a copy of `choice` with `disable_parallel_tool_use = true`.
    /// Anthropic only honours the flag on auto/any/tool — `.none` has no parallel toggle.
    static func disableParallel(on choice: AnthropicToolChoice) -> AnthropicToolChoice {
        switch choice {
            case .auto:
                return .auto(disableParallel: true)
            case .any:
                return .any(disableParallel: true)
            case let .tool(name, _):
                return .tool(name: name, disableParallel: true)
            case .none:
                return .none
        }
    }

    /// Wraps an `AnthropicMessagesResponse` into the Responses API `Response`
    /// shape so the Agents SDK can consume it like an OpenAI response.
    static func makeResponse(
        model: String,
        instructions: String?,
        response: AnthropicMessagesResponse
    ) -> Response {
        let outputs = outputItems(from: response.content)
        let usage = responsesUsage(from: response.usage)

        return Response(
            id: response.id,
            createdAt: Date(),
            completedAt: Date(),
            status: .completed,
            background: nil,
            error: nil,
            incompleteDetails: nil,
            instructions: instructions,
            maxOutputTokens: nil,
            model: response.model.isEmpty ? model : response.model,
            output: outputs,
            outputText: nil,
            parallelToolCalls: nil,
            previousResponseId: nil,
            reasoning: nil,
            temperature: nil,
            text: TextConfiguration(format: .text),
            toolChoice: .auto,
            tools: [],
            topP: nil,
            truncation: nil,
            usage: usage,
            user: nil,
            metadata: nil,
            serviceTier: nil
        )
    }
}
