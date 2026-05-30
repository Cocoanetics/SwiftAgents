//
//  OpenAI+Compact.swift
//  SwiftAgents
//
//  The standalone `/responses/compact` endpoint: summarize a long-running
//  conversation into a smaller, re-sendable window. Orthogonal to the
//  transport — it's a plain HTTP request, so `OpenAIResponsesWebSocket`
//  inherits it and runs it alongside its socket.
//
//  SeeAlso: [Compact a response](https://platform.openai.com/docs/api-reference/responses/compact)
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension OpenAI {
    /// Compact a conversation via `POST /v1/responses/compact`.
    ///
    /// Summarizes older turns into an opaque `compaction` item while keeping
    /// recent items verbatim. Reach for it when a long conversation approaches
    /// the context limit: compact, then start a **new** chain from the returned
    /// ``CompactedResponse/input`` (with `previousResponseId == nil`) and append
    /// new turns from there.
    ///
    /// Provide `previousResponseId` to compact a stored chain, and/or `input`
    /// to compact items you hold client-side (the path that works under
    /// `store=false` / Zero Data Retention).
    ///
    /// - Parameters:
    ///   - model: Model ID used to perform the compaction.
    ///   - input: Items to compact. Omit to compact purely from `previousResponseId`.
    ///   - instructions: Optional system/developer message for the compaction pass.
    ///   - previousResponseId: Compact the stored conversation ending at this response.
    ///   - promptCacheKey: Optional key for reading/writing the prompt cache.
    ///   - promptCacheRetention: Optional prompt-cache retention policy.
    ///   - serviceTier: Optional latency tier for the request.
    /// - Returns: A ``CompactedResponse`` whose ``CompactedResponse/input`` seeds the next chain.
    func compactResponse(
        model: String,
        input: Response.Input? = nil,
        instructions: String? = nil,
        previousResponseId: String? = nil,
        promptCacheKey: String? = nil,
        promptCacheRetention: Response.PromptCacheRetention? = nil,
        serviceTier: ServiceTier? = nil
    ) async throws -> CompactedResponse {
        let body = CompactRequest(
            model: model,
            input: input,
            instructions: instructions,
            previousResponseId: previousResponseId,
            promptCacheKey: promptCacheKey,
            promptCacheRetention: promptCacheRetention,
            serviceTier: serviceTier
        )

        let request = try createUrlRequest(httpMethod: "POST", path: "/v1/responses/compact", body: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try process(data: data, response: response)
    }
}

/// Wire body for `POST /v1/responses/compact` — a strict subset of the create
/// parameters (the only fields the endpoint accepts). Optionals are nil-omitted
/// by the synthesized encoder, so an absent field never reaches the wire.
/// `Codable` (not just `Encodable`) to satisfy `createUrlRequest(body:)`, which
/// takes `Codable?` — matching `ResponseOptionals`.
private struct CompactRequest: Codable {
    let model: String
    let input: Response.Input?
    let instructions: String?
    let previousResponseId: String?
    let promptCacheKey: String?
    let promptCacheRetention: Response.PromptCacheRetention?
    let serviceTier: ServiceTier?
}
