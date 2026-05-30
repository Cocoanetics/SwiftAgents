//
//  CompactedResponse.swift
//  SwiftAgents
//
//  The result of `POST /v1/responses/compact`.
//
//  SeeAlso: [Compact a response](https://platform.openai.com/docs/api-reference/responses/compact)
//

import Foundation
import SwiftMCP

/// A compacted snapshot of a conversation, returned by
/// ``OpenAI/compactResponse(model:input:instructions:previousResponseId:promptCacheKey:promptCacheRetention:serviceTier:)``.
///
/// The service summarizes older turns into an opaque `compaction` item while
/// keeping recent items verbatim, so the whole window fits back inside the
/// context budget. Continue by starting a **new** chain: send ``input`` as the
/// next turn's seed with `previousResponseId == nil`, then append new items.
/// The window is forwarded as-is — nothing is pruned — which is what keeps it
/// valid under `store=false` / Zero Data Retention.
///
/// `output` is captured as raw ``JSONValue`` items, not the narrower typed
/// `OutputItem`/`ResponseItem`. A compacted window deliberately mixes shapes the
/// assistant-output models reject — user messages with `input_text` content, a
/// `compaction` item whose opaque `encrypted_content` must survive intact, and
/// any tool item — so capturing each verbatim is what keeps the forward path
/// lossless and forward-compatible.
public struct CompactedResponse: Codable, Sendable {
    /// Unique identifier for this compacted response.
    public let id: String

    /// Unix timestamp (in seconds) of when the compacted conversation was created.
    public let createdAt: Date

    /// The object type. Always `response.compaction`.
    public var object = "response.compaction"

    /// The compacted list of items, captured verbatim as raw JSON. Re-send these
    /// via ``input`` to continue from the compacted window.
    public let output: [JSONValue]

    /// Token accounting for the compaction pass.
    public let usage: ResponsesUsage?

    private enum CodingKeys: String, CodingKey {
        case id
        case object
        case createdAt
        case output
        case usage
    }

    public init(
        id: String,
        createdAt: Date,
        object: String = "response.compaction",
        output: [JSONValue],
        usage: ResponsesUsage? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.object = object
        self.output = output
        self.usage = usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        object = try container.decodeIfPresent(String.self, forKey: .object) ?? "response.compaction"
        output = try container.decodeIfPresent([JSONValue].self, forKey: .output) ?? []
        usage = try container.decodeIfPresent(ResponsesUsage.self, forKey: .usage)
    }
}

public extension CompactedResponse {
    /// The compacted window as a `Response.Input`, ready to seed a **new** chain.
    ///
    /// Pass this as the next turn's input with `previousResponseId == nil` (the
    /// compacted summary stands in for the prior chain), then append any new
    /// user items. Items are forwarded verbatim — no pruning, no reshaping —
    /// each as a ``Response/Input/Element/raw(_:)`` element.
    var input: Response.Input {
        .array(output.map { .raw($0) })
    }

    /// Whether the window contains a `compaction` summary item. `false` when the
    /// conversation was short enough that the service returned only plain items.
    var containsCompactionSummary: Bool {
        output.contains { $0["type"]?.stringValue == "compaction" }
    }
}
