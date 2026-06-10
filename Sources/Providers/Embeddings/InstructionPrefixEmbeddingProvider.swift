//
//  InstructionPrefixEmbeddingProvider.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 10.06.26.
//

import Foundation

/// Wraps any `EmbeddingProvider` and applies a model's query vs. document prompt
/// template, so the `EmbeddingRole` plumbed through the store actually changes
/// the embedding. Symmetric embedders (OpenAI `text-embedding-3`, Apple
/// `NLContextualEmbedding`) need no wrapper; instruction-tuned ones
/// (embeddinggemma / nomic / e5 / Qwen3-Embedding, typically served via Ollama)
/// retrieve markedly better when the query and the document are prefixed
/// differently — without it both roles embed identically and the asymmetry the
/// model was trained on is silently lost.
///
/// The wrapper is transport-agnostic: the prefix is a property of the model
/// *family*, not of how it's served, so the same `.embeddinggemma` template
/// works whether the wrapped provider is Ollama today or a local GGUF/MLX
/// provider later. `embeddingModelIdentifier` forwards to the wrapped provider,
/// so the real model is still what the store records for embed-fingerprinting.
public final class InstructionPrefixEmbeddingProvider: EmbeddingProvider {

    /// A query/document prompt template for an instruction-tuned embedder. Every
    /// known family encodes its asymmetry as a plain prefix, so two strings
    /// suffice (a one-sided model uses an empty prefix on the other side).
    public struct Template: Sendable {
        public let queryPrefix: String
        public let documentPrefix: String

        public init(queryPrefix: String, documentPrefix: String) {
            self.queryPrefix = queryPrefix
            self.documentPrefix = documentPrefix
        }

        /// `embeddinggemma` — the qmd default. A markdown-chunk store has no
        /// per-chunk title, so the title field carries the model's `none`
        /// sentinel; this matches qmd's document template byte-for-byte, so an
        /// index built here is vector-compatible with one built by qmd.
        public static let embeddinggemma = Template(
            queryPrefix: "task: search result | query: ",
            documentPrefix: "title: none | text: ")

        /// `nomic-embed-text`.
        public static let nomic = Template(
            queryPrefix: "search_query: ",
            documentPrefix: "search_document: ")

        /// `intfloat/e5` family.
        public static let e5 = Template(
            queryPrefix: "query: ",
            documentPrefix: "passage: ")

        /// `Qwen3-Embedding`: an instruction on the query side only — documents
        /// are embedded as raw text, modeled here as an empty document prefix.
        public static let qwen3 = Template(
            queryPrefix: "Instruct: Retrieve relevant documents for the given query\nQuery: ",
            documentPrefix: "")

        /// Best-effort template for a known instruction-tuned model, matched on
        /// its identifier (e.g. `"embeddinggemma:300m"`, `"nomic-embed-text"`,
        /// `"qwen3-embedding:0.6b"`). Returns `nil` for unknown or symmetric
        /// models — the caller should then leave the provider unwrapped.
        public static func matching(modelIdentifier: String) -> Template? {
            let lower = modelIdentifier.lowercased()
            if lower.contains("qwen"), lower.contains("embed") { return .qwen3 }
            if lower.contains("embeddinggemma") || lower.contains("embedding-gemma") {
                return .embeddinggemma
            }
            if lower.contains("nomic") { return .nomic }
            if lower.contains("e5") { return .e5 }
            return nil
        }
    }

    private let wrapped: EmbeddingProvider
    private let template: Template

    public init(wrapping provider: EmbeddingProvider, template: Template) {
        self.wrapped = provider
        self.template = template
    }

    public var embeddingModelIdentifier: String {
        get { wrapped.embeddingModelIdentifier }
        set { wrapped.embeddingModelIdentifier = newValue }
    }

    /// Role-less embedding can't pick a side, so it delegates unprefixed — the
    /// store always calls the role-aware overload below.
    public func embedding(for text: String) async throws -> Vector? {
        try await wrapped.embedding(for: text)
    }

    public func embedding(for text: String, role: EmbeddingRole) async throws -> Vector? {
        let prefix = role == .query ? template.queryPrefix : template.documentPrefix
        return try await wrapped.embedding(for: prefix + text)
    }
}
