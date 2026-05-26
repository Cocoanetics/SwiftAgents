//
//  ConversationStatePolicy.swift
//  SwiftAgents
//
//  Describes how a provider handles conversation state and how its response
//  identifiers should be exported to tracing.
//
//  Two orthogonal axes:
//
//  1. `supportsServerSideHistory` — the endpoint stores conversation state and
//     accepts a `previousResponseId` so callers don't need to resend prior
//     turns. True for OpenAI's Responses API and LM Studio's native
//     `/api/v1/chat`. False for stateless surfaces like OpenAI Chat
//     Completions, Ollama, and Anthropic Messages.
//
//  2. `responseIdsAreOpenAIRoutable` — the response id this provider hands
//     back is something OpenAI's trace ingestion can resolve. True only for
//     OpenAI proper. False for everyone else, including OpenAI-compatible
//     local servers, even when they happen to use the Responses-shaped wire.
//     When false, the Runner emits `GenerationSpanData` (carries the full
//     input/output payload) instead of `ResponseSpanData` (carries only the
//     bare id) so spans render without a follow-up lookup against OpenAI.

import Foundation

/// Per-`API` declaration of how the provider chains conversation state and
/// how its response ids should appear in tracing. See file header for the
/// two axes and how the Runner uses them.
public struct ConversationStatePolicy: Sendable, Equatable {
    /// True if the provider stores conversation state server-side and accepts
    /// a `previousResponseId` for chaining; the Runner can skip resending
    /// prior turns.
    public var supportsServerSideHistory: Bool

    /// True only if the response id this provider returns is something
    /// OpenAI's trace ingestion can resolve. Determines whether the Runner
    /// emits `ResponseSpanData` (id-only) or `GenerationSpanData` (full
    /// input/output) for each turn.
    public var responseIdsAreOpenAIRoutable: Bool

    /// True if the provider's stateful path honors structured output
    /// (`json` / `json_schema` response formats). LM Studio's native
    /// `/api/v1/chat` doesn't take any schema field today — only its
    /// OpenAI-compat `/v1/chat/completions` does. When this is false and
    /// the agent declares a structured `OutputType`, the Runner falls back
    /// to chat completions for that turn so callers still get a decoded
    /// result instead of free-form text the decoder will reject.
    public var supportsStructuredOutput: Bool

    public init(
        supportsServerSideHistory: Bool,
        responseIdsAreOpenAIRoutable: Bool,
        supportsStructuredOutput: Bool = true
    ) {
        self.supportsServerSideHistory = supportsServerSideHistory
        self.responseIdsAreOpenAIRoutable = responseIdsAreOpenAIRoutable
        self.supportsStructuredOutput = supportsStructuredOutput
    }

    /// OpenAI Responses API: stateful, produces ids OpenAI can resolve, and
    /// supports structured output natively.
    public static let openAIResponses = ConversationStatePolicy(
        supportsServerSideHistory: true,
        responseIdsAreOpenAIRoutable: true,
        supportsStructuredOutput: true
    )

    /// LM Studio's native `/api/v1/chat`: stateful, but the ids belong to
    /// LM Studio and aren't resolvable by OpenAI's trace dashboard, and
    /// the endpoint doesn't accept a JSON schema. Structured-output runs
    /// route through the OpenAI-compat `/v1/chat/completions` instead.
    public static let lmStudioNative = ConversationStatePolicy(
        supportsServerSideHistory: true,
        responseIdsAreOpenAIRoutable: false,
        supportsStructuredOutput: false
    )

    /// Stateless providers (Anthropic Messages, OpenAI Chat Completions,
    /// Ollama, …). The caller is responsible for assembling history; spans
    /// are emitted as `GenerationSpanData`. Structured output is honored
    /// via `response_format` on the chat-completions wire.
    public static let stateless = ConversationStatePolicy(
        supportsServerSideHistory: false,
        responseIdsAreOpenAIRoutable: false,
        supportsStructuredOutput: true
    )
}
