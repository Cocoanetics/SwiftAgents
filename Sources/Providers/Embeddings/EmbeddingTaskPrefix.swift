//
//  EmbeddingTaskPrefix.swift
//  SwiftAgents
//
//  Task-instruction prefixes for instruction-tuned embedding models.
//  Families like nomic-embed and EmbeddingGemma are trained on an
//  asymmetric prompt format and document it as required usage: queries
//  and documents must each carry their task prefix, or retrieval quality
//  collapses (nomic-embed-text-v2-moe mis-ranks even a four-document
//  corpus when embedded bare). Symmetric models (OpenAI text-embedding-3,
//  Apple NLContextualEmbedding) need none and match no family here.
//

import Foundation

/// The documented query/document instruction pair for an instruction-tuned
/// embedding model family. Applied by the default role-aware
/// ``EmbeddingProvider/embedding(for:role:)`` — the symmetric
/// ``EmbeddingProvider/embedding(for:)`` is never prefixed, so callers that
/// embed free-form text (similarity, clustering) keep their semantics.
public struct EmbeddingTaskPrefix: Sendable, Equatable {
    /// Prepended when embedding a search query (`EmbeddingRole.query`).
    public let query: String
    /// Prepended when embedding indexed content (`EmbeddingRole.document`).
    public let document: String

    public init(query: String, document: String) {
        self.query = query
        self.document = document
    }

    /// `text` with the prefix for `role` prepended. Text that already starts
    /// with either prefix passes through unchanged, so callers migrating from
    /// manual prefixing don't end up with a double prefix.
    public func apply(to text: String, role: EmbeddingRole) -> String {
        guard !text.hasPrefix(query), !text.hasPrefix(document) else { return text }
        switch role {
            case .query: return query + text
            case .document: return document + text
        }
    }

    /// The documented prefix pair for `modelID`, or nil for models that embed
    /// symmetrically. Matched on a family substring so every provider's id
    /// form resolves: `text-embedding-nomic-embed-text-v1.5` (LM Studio),
    /// `nomic-embed-text:latest` (Ollama), `embeddinggemma-300m`, …
    public static func forModel(_ modelID: String) -> EmbeddingTaskPrefix? {
        let id = modelID.lowercased()
        if id.contains("nomic-embed") {
            // https://huggingface.co/nomic-ai/nomic-embed-text-v2-moe
            return EmbeddingTaskPrefix(query: "search_query: ", document: "search_document: ")
        }
        if id.contains("embeddinggemma") {
            // https://ai.google.dev/gemma/docs/embeddinggemma — retrieval prompts.
            return EmbeddingTaskPrefix(query: "task: search result | query: ", document: "title: none | text: ")
        }
        return nil
    }
}
