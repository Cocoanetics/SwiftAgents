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
//  This is the single source of truth for the known templates: the
//  protocol default `embedding(for:role:)` applies them automatically by
//  model id, and `InstructionPrefixEmbeddingProvider` exposes the same
//  presets for explicit wrapping / custom templates.
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
    /// manual prefixing don't end up with a double prefix. Empty prefixes
    /// (several families embed documents raw) are skipped by that guard —
    /// every string "starts with" the empty string.
    public func apply(to text: String, role: EmbeddingRole) -> String {
        let markers = [query, document].filter { !$0.isEmpty }
        guard !markers.contains(where: text.hasPrefix) else { return text }
        switch role {
            case .query: return query + text
            case .document: return document + text
        }
    }

    // MARK: - Known families

    /// nomic-embed (v1.5 / v2-moe) and modernbert-embed — the shared nomic
    /// task prefixes. https://huggingface.co/nomic-ai/nomic-embed-text-v2-moe
    public static let nomic = EmbeddingTaskPrefix(
        query: "search_query: ",
        document: "search_document: "
    )

    /// EmbeddingGemma and gemini-embedding-2 — the Gemma retrieval prompts
    /// (https://ai.google.dev/gemma/docs/embeddinggemma). A markdown-chunk
    /// store has no per-chunk title, so the title field carries the model's
    /// `none` sentinel; this matches qmd's document template byte-for-byte,
    /// so an index built here is vector-compatible with one built by qmd.
    public static let embeddinggemma = EmbeddingTaskPrefix(
        query: "task: search result | query: ",
        document: "title: none | text: "
    )

    /// intfloat/e5 family.
    public static let e5 = EmbeddingTaskPrefix(
        query: "query: ",
        document: "passage: "
    )

    /// Qwen3-Embedding: an instruction on the query side only — documents are
    /// embedded as raw text, modeled here as an empty document prefix.
    /// https://huggingface.co/Qwen/Qwen3-Embedding-0.6B
    public static let qwen3 = EmbeddingTaskPrefix(
        query: "Instruct: Retrieve relevant documents for the given query\nQuery: ",
        document: ""
    )

    /// mxbai-embed: instructed queries, raw documents.
    /// https://huggingface.co/mixedbread-ai/mxbai-embed-large-v1
    public static let mxbai = EmbeddingTaskPrefix(
        query: "Represent this sentence for searching relevant passages: ",
        document: ""
    )

    /// The documented prefix pair for `modelID`, or nil for models that embed
    /// symmetrically. Matched by family substring so every provider's id form
    /// resolves: `text-embedding-nomic-embed-text-v1.5` (LM Studio),
    /// `nomic-embed-text:latest` (Ollama), `embeddinggemma-300m`, … The
    /// matchers are deliberately tight — bare "nomic" would also match
    /// "economic", bare "e5" matches version suffixes like "v1.5".
    public static func forModel(_ modelID: String) -> EmbeddingTaskPrefix? {
        let id = modelID.lowercased()
        if id.contains("nomic-embed") || id.contains("modernbert-embed") {
            return .nomic
        }
        if id.contains("embeddinggemma") || id.contains("embedding-gemma") || id.contains("gemini-embedding-2") {
            // gemini-embedding-001 predates prompt instructions and matches
            // nothing here — its role handling is the `taskType` API
            // parameter, applied by `GoogleAPI`'s conformance.
            return .embeddinggemma
        }
        if id.contains("qwen3-embedding") {
            return .qwen3
        }
        if id.contains("mxbai-embed") {
            return .mxbai
        }
        if id.contains("e5-") {
            return .e5
        }
        return nil
    }
}
