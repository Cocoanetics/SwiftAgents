//
//  LMStudio+Chat.swift
//  SwiftAgents
//
//  Mirrors `OpenAI.createResponse` for LM Studio's native `/api/v1/chat`
//  endpoint. The native endpoint is stateful: the server stores the
//  conversation and the client passes `previous_response_id` to continue it,
//  so we never resend history. The wire shape is Responses-API-flavored
//  (`input`, `output`, `response_id`) but slightly simpler — message
//  `output[].content` may be a plain string instead of the structured
//  `[output_text]` array.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension LMStudio {
    /// Prefix on synthetic `Response.id` values used when LM Studio omits a
    /// real `response_id` (i.e. the caller asked for `store: false`). The
    /// Runner stashes the synthetic id on `turnState.previousResponse`, so
    /// the next `createResponse` call would round-trip it as
    /// `previous_response_id` — which LM Studio would reject. We strip the
    /// sentinel here instead of asking the Runner to know about it.
    static let statelessIdPrefix = "lmstudio_stateless_"

    /// Posts to `/api/v1/chat` and converts the result into a Responses-API
    /// `Response`. Parameter list mirrors `OpenAI.createResponse` so callers
    /// (notably the Agents runner) can dispatch uniformly across providers.
    func createResponse(
        input: Response.Input,
        model: String,
        instructions: String? = nil,
        maxOutputTokens: Int? = nil,
        metadata: [String: String]? = nil,
        parallelToolCalls _: Bool? = nil,
        previousResponseId: String? = nil,
        reasoning _: Reasoning? = nil,
        store: Bool? = nil,
        temperature: Double? = nil,
        textFormat _: TextFormat? = nil,
        toolChoice: ToolChoice? = nil,
        tools: [Tool]? = nil,
        topP: Double? = nil,
        truncation _: Response.TruncationStrategy? = nil,
        user _: String? = nil
    ) async throws -> Response {
        let chainableId = previousResponseId.flatMap { id in
            id.hasPrefix(LMStudio.statelessIdPrefix) ? nil : id
        }

        let body = LMStudioChatRequest(
            model: model,
            input: input,
            previousResponseId: chainableId,
            store: store,
            instructions: instructions,
            tools: tools,
            toolChoice: toolChoice,
            temperature: temperature,
            topP: topP,
            maxOutputTokens: maxOutputTokens,
            metadata: metadata
        )

        let request = try createUrlRequest(httpMethod: "POST", path: "/api/v1/chat", body: body)

        let (data, response) = try await session.data(for: request)
        let lmstudio: LMStudioChatResponse = try process(data: data, response: response)
        return lmstudio.toResponse(modelHint: model, instructions: instructions)
    }
}

// MARK: - Wire types

/// Request body for `POST /api/v1/chat`. Field names are camelCase here; the
/// shared `API.encoder` rewrites them to snake_case on the wire.
struct LMStudioChatRequest: Codable {
    let model: String
    let input: Response.Input
    let previousResponseId: String?
    let store: Bool?
    let instructions: String?
    let tools: [Tool]?
    let toolChoice: ToolChoice?
    let temperature: Double?
    let topP: Double?
    let maxOutputTokens: Int?
    let metadata: [String: String]?
}

/// Response body from `POST /api/v1/chat`. Most fields are optional — when
/// `store: false` is requested LM Studio omits `response_id`, and older
/// builds may not return `usage`.
public struct LMStudioChatResponse: Codable, Sendable {
    public let responseId: String?
    public let modelInstanceId: String?
    public let model: String?
    public let output: [LMStudioOutputItem]
    public let usage: ResponsesUsage?
}

/// One element of the LM Studio `output` array. LM Studio's native chat
/// endpoint emits a few simpler shapes than the OpenAI Responses API:
///   - `{type: "message", content: <string>}` for assistant text
///   - `{type: "reasoning", content: <string>}` for chain-of-thought
///     summaries (no `id`, no `summary` field)
/// For tool calls and other structured items the wire matches the OpenAI
/// shape. We try the simple forms first; everything else falls through to
/// the standard `OutputItem` decoder.
public enum LMStudioOutputItem: Codable, Sendable {
    case message(id: String?, content: String)
    case reasoning(content: String)
    case raw(OutputItem)

    public init(from decoder: Decoder) throws {
        let typed = try? decoder.container(keyedBy: TypedKeys.self)
        if let type = try? typed?.decode(String.self, forKey: .type) {
            switch type {
                case "message":
                    if let raw = try? decoder.container(keyedBy: TypedKeys.self),
                       let content = try? raw.decode(String.self, forKey: .content) {
                        let id = try? raw.decodeIfPresent(String.self, forKey: .id)
                        self = .message(id: id, content: content)
                        return
                    }
                case "reasoning":
                    // LM Studio's reasoning shape lacks the `id` /
                    // `summary` fields that `OutputItem.ReasoningOutput`
                    // expects, so the standard decoder would throw on it.
                    if let raw = try? decoder.container(keyedBy: TypedKeys.self),
                       let content = try? raw.decode(String.self, forKey: .content) {
                        self = .reasoning(content: content)
                        return
                    }
                default:
                    break
            }
        }
        self = try .raw(OutputItem(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
            case let .message(id, content):
                var container = encoder.container(keyedBy: TypedKeys.self)
                try container.encode("message", forKey: .type)
                if let id { try container.encode(id, forKey: .id) }
                try container.encode(content, forKey: .content)
            case let .reasoning(content):
                var container = encoder.container(keyedBy: TypedKeys.self)
                try container.encode("reasoning", forKey: .type)
                try container.encode(content, forKey: .content)
            case let .raw(item):
                try item.encode(to: encoder)
        }
    }

    private enum TypedKeys: String, CodingKey {
        case type
        case id
        case content
    }
}

extension LMStudioOutputItem {
    /// Lifts the LM Studio shape into a standard `OutputItem` so the
    /// rest of the runner doesn't need to know LM Studio existed.
    func toOutputItem() -> OutputItem {
        switch self {
            case let .message(id, content):
                return .message(.init(
                    id: id ?? UUID().uuidString,
                    role: .assistant,
                    status: .completed,
                    content: [.outputText(.init(text: content, annotations: []))]
                ))
            case let .reasoning(content):
                return .reasoning(.init(
                    id: UUID().uuidString,
                    status: .completed,
                    summary: [.init(type: "summary_text", text: content)]
                ))
            case let .raw(item):
                return item
        }
    }
}

extension LMStudioChatResponse {
    /// Synthesise a Responses-API `Response` from the LM Studio body so the
    /// Agents runner can consume it uniformly. Missing fields get sensible
    /// defaults; `id` falls back to a synthetic UUID when LM Studio omits
    /// `response_id` (i.e. the caller passed `store: false`).
    func toResponse(modelHint: String, instructions: String?) -> Response {
        let outputs = output.map { $0.toOutputItem() }
        return Response(
            id: responseId ?? "\(LMStudio.statelessIdPrefix)\(UUID().uuidString)",
            createdAt: Date(),
            completedAt: Date(),
            status: .completed,
            background: nil,
            error: nil,
            incompleteDetails: nil,
            instructions: instructions,
            maxOutputTokens: nil,
            model: model ?? modelInstanceId ?? modelHint,
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
