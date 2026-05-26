//
//  Anthropic+Responses.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.05.26.
//
//  The OpenAI Responses API surface, backed by Anthropic's Messages API.
//  This is the entry point the Agents SDK runner uses.

import Foundation
import SwiftMCP
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
        textFormat: TextFormat? = nil,
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
            textFormat: textFormat,
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
        textFormat: TextFormat? = nil,
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
            textFormat: textFormat,
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
        textFormat: TextFormat? = nil,
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
            metadata: user.map { AnthropicMessagesRequest.Metadata(userId: $0) },
            outputConfig: Anthropic.convertOutputConfig(from: textFormat)
        )

        return (request, priorMessages)
    }
}

extension Anthropic {
    /// Translate the OpenAI-shaped `TextFormat` into Anthropic's native
    /// `output_config` payload. Only `.jsonSchema` produces one — `.text`
    /// and `.json` (JSON-mode without a schema) leave it nil so the
    /// model replies normally. The schema is run through
    /// `sanitizedForAnthropic(_:)` to drop fields Anthropic's
    /// json_schema validator rejects (`minimum`, `maximum`, `pattern`,
    /// `$ref`, etc.) — see
    /// https://platform.claude.com/docs/en/build-with-claude/structured-outputs.
    /// `additionalProperties: false` is REQUIRED by Anthropic and is
    /// what the `@Schema` macro already emits, so it's kept verbatim.
    static func convertOutputConfig(from textFormat: TextFormat?) -> AnthropicMessagesRequest.OutputConfig? {
        guard case let .jsonSchema(format) = textFormat else { return nil }
        let sanitised = sanitizedSchemaForAnthropic(format.schema)
        return AnthropicMessagesRequest.OutputConfig(
            format: .init(schema: sanitised)
        )
    }

    /// Chat-completion variant — same translation, different source
    /// enum. The chat-completion fallback path in the Runner is the
    /// one Anthropic actually takes because `Anthropic` does not
    /// conform to `ServerHistoryAPI`, so this is the wiring that
    /// matters in practice.
    static func convertOutputConfig(
        from responseFormat: ChatCompletionRequest.ResponseFormat?
    ) -> AnthropicMessagesRequest.OutputConfig? {
        guard case let .jsonSchema(format) = responseFormat else { return nil }
        let sanitised = sanitizedSchemaForAnthropic(format.schema)
        return AnthropicMessagesRequest.OutputConfig(
            format: .init(schema: sanitised)
        )
    }

    /// Strip JSON-Schema features Anthropic's `output_config.format`
    /// does not support, recursively. Anthropic accepts:
    ///   type, properties, required, items, enum, const, anyOf, oneOf,
    ///   description, additionalProperties (must be false),
    ///   propertyOrdering.
    /// And rejects: minimum/maximum/multipleOf, minLength/maxLength,
    /// pattern, minItems/maxItems (mostly), `$ref`, `$schema`,
    /// `definitions`/`$defs`, recursive schemas.
    static func sanitizedSchemaForAnthropic(_ schema: JSONSchema) -> JSONSchema {
        // Round-trip through JSON so we can strip arbitrary keys without
        // mutating the typed schema. The @Schema macro emits a fairly
        // tight subset already, but tools defined elsewhere in the SDK
        // may inject minLength/pattern hints that would 400 Anthropic.
        let disallowed: Set<String> = [
            "minimum", "maximum", "multipleOf",
            "minLength", "maxLength", "pattern",
            "maxItems",
            "$ref", "$schema",
            "definitions", "$defs",
            "patternProperties"
        ]
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(schema) else { return schema }
        guard var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return schema
        }
        dict = stripKeys(dict, disallowed: disallowed)
        guard let restored = try? JSONSerialization.data(withJSONObject: dict),
              let sanitised = try? JSONDecoder().decode(JSONSchema.self, from: restored) else {
            return schema
        }
        return sanitised
    }

    private static func stripKeys(_ raw: [String: Any], disallowed: Set<String>) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in raw where !disallowed.contains(key) {
            out[key] = stripKeysFromAny(value, disallowed: disallowed)
        }
        return out
    }

    private static func stripKeysFromAny(_ value: Any, disallowed: Set<String>) -> Any {
        if let dict = value as? [String: Any] {
            return stripKeys(dict, disallowed: disallowed)
        }
        if let arr = value as? [Any] {
            return arr.map { stripKeysFromAny($0, disallowed: disallowed) }
        }
        return value
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
