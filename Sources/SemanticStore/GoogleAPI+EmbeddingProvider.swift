//
//  GoogleAPI+EmbeddingProvider.swift
//  SwiftAgents
//
//  Gemini embeddings for the vector stores. The two model generations
//  carry the retrieval role differently, so the role-aware path splits:
//  `gemini-embedding-001` gets the `taskType` API parameter, everything
//  else falls back to the shared `EmbeddingTaskPrefix` prompt table
//  (which `gemini-embedding-2` matches — it shares EmbeddingGemma's
//  retrieval prompt format).
//

import Foundation
import Providers

extension GoogleAPI: EmbeddingProvider {
    public func embedding(for text: String) async throws -> Vector? {
        try await embedContent(text, model: embeddingModelIdentifier).unitVector()
    }

    public func embedding(for text: String, role: EmbeddingRole) async throws -> Vector? {
        // gemini-embedding-001 predates prompt instructions: the role is an
        // API parameter, not a prefix.
        if embeddingModelIdentifier.contains("gemini-embedding-001") {
            let task: GoogleEmbeddingTaskType = role == .query ? .retrievalQuery : .retrievalDocument
            return try await embedContent(text, model: embeddingModelIdentifier, taskType: task).unitVector()
        }
        // Everything else mirrors the protocol default: documented prompt
        // prefixes when the model has a known family, symmetric otherwise.
        guard let prefix = EmbeddingTaskPrefix.forModel(embeddingModelIdentifier) else {
            return try await embedding(for: text)
        }
        return try await embedding(for: prefix.apply(to: text, role: role))
    }
}
