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

    public init(
        supportsServerSideHistory: Bool,
        responseIdsAreOpenAIRoutable: Bool
    ) {
        self.supportsServerSideHistory = supportsServerSideHistory
        self.responseIdsAreOpenAIRoutable = responseIdsAreOpenAIRoutable
    }

    /// OpenAI Responses API: stateful and produces ids OpenAI can resolve.
    public static let openAIResponses = ConversationStatePolicy(
        supportsServerSideHistory: true,
        responseIdsAreOpenAIRoutable: true
    )

    /// LM Studio's native `/api/v1/chat`: stateful, but the ids belong to
    /// LM Studio and aren't resolvable by OpenAI's trace dashboard.
    public static let lmStudioNative = ConversationStatePolicy(
        supportsServerSideHistory: true,
        responseIdsAreOpenAIRoutable: false
    )

    /// Stateless providers (Anthropic Messages, OpenAI Chat Completions,
    /// Ollama, …). The caller is responsible for assembling history; spans
    /// are emitted as `GenerationSpanData`.
    public static let stateless = ConversationStatePolicy(
        supportsServerSideHistory: false,
        responseIdsAreOpenAIRoutable: false
    )
}
