//
//  InstructionPrefixEmbeddingProvider.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 10.06.26.
//

import Foundation

/// Wraps any `EmbeddingProvider` and applies a query vs. document prompt
/// template, so the `EmbeddingRole` plumbed through the store changes the
/// embedding the way the model was trained for.
///
/// Known instruction-tuned families (nomic / EmbeddingGemma / Qwen3 / e5 /
/// mxbai) don't need this wrapper: the protocol's default
/// `embedding(for:role:)` already applies their documented prefixes by
/// matching `embeddingModelIdentifier` against ``EmbeddingTaskPrefix``. Reach
/// for the wrapper when the model id is opaque (a local GGUF/MLX provider
/// with a generic identifier), or to force a custom template the table
/// doesn't know.
///
/// The wrapper is transport-agnostic: the prefix is a property of the model
/// *family*, not of how it's served, so the same `.embeddinggemma` template
/// works whether the wrapped provider is Ollama today or a local GGUF/MLX
/// provider later. `embeddingModelIdentifier` forwards to the wrapped
/// provider, so the real model is still what the store records for
/// embed-fingerprinting — note that the store's fingerprint renders the
/// *table's* template for that id, so a custom template that deviates from
/// the table is not visible to fingerprint-based index invalidation.
public final class InstructionPrefixEmbeddingProvider: EmbeddingProvider {

    /// A query/document prompt template for an instruction-tuned embedder — a
    /// thin veneer over ``EmbeddingTaskPrefix``, which holds the actual prompt
    /// strings, so the wrapper and the automatic role-aware default can never
    /// drift apart.
    public struct Template: Sendable {
        let prefix: EmbeddingTaskPrefix

        public var queryPrefix: String { prefix.query }
        public var documentPrefix: String { prefix.document }

        public init(queryPrefix: String, documentPrefix: String) {
            self.init(EmbeddingTaskPrefix(query: queryPrefix, document: documentPrefix))
        }

        init(_ prefix: EmbeddingTaskPrefix) {
            self.prefix = prefix
        }

        /// `embeddinggemma` / `gemini-embedding-2` — the Gemma retrieval
        /// prompts, byte-compatible with indexes built by qmd.
        public static let embeddinggemma = Template(.embeddinggemma)

        /// `nomic-embed-text` / `modernbert-embed`.
        public static let nomic = Template(.nomic)

        /// `intfloat/e5` family.
        public static let e5 = Template(.e5)

        /// `Qwen3-Embedding`: an instruction on the query side only — documents
        /// are embedded as raw text, modeled here as an empty document prefix.
        public static let qwen3 = Template(.qwen3)

        /// `mxbai-embed`: instructed queries, raw documents.
        public static let mxbai = Template(.mxbai)

        /// Best-effort template for a known instruction-tuned model, matched on
        /// its identifier (e.g. `"embeddinggemma:300m"`, `"nomic-embed-text"`,
        /// `"qwen3-embedding:0.6b"`). Returns `nil` for unknown or symmetric
        /// models — the caller should then leave the provider unwrapped.
        public static func matching(modelIdentifier: String) -> Template? {
            EmbeddingTaskPrefix.forModel(modelIdentifier).map(Template.init)
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
        try await wrapped.embedding(for: template.prefix.apply(to: text, role: role))
    }
}
