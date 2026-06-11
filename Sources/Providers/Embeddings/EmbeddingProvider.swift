//
//  EmbeddingProvider.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 19.04.24.
//

import Foundation

/// A vector of floating-point values used to represent text embeddings,
/// average vectors, and similarity comparisons.
///
/// Defined in `Providers` so the protocol and the wire types
/// (`OllamaEmbeddingResponse.embedding`, `EmbeddingVector.embedding`)
/// both reference it without pulling the `SemanticStore`
/// target. The vector-math extensions (cosine similarity, magnitude,
/// average, etc.) live in `SemanticStore/Array+Vector.swift` and use
/// `Accelerate` — Apple-only.
public typealias Vector = [Double]

/// Whether a text is being embedded as a search **query** or as an indexed
/// **document**. Symmetric embedders (Apple `NLContextualEmbedding`, OpenAI
/// text-embedding-3) ignore it; instruction-tuned embedders (nomic / bge / e5 /
/// Qwen3-Embedding, e.g. served via Ollama) embed the two roles differently and
/// retrieve markedly better when the asymmetry is honored.
public enum EmbeddingRole: Sendable {
    case query
    case document
}

/// Protocol for providing embeddings. Gives a `modelIdentifier` for the semantic stores to identify with which provider
/// embeddings were created.
///  - note: It's based on `AnyObject` so that we can set the `embeddingModelIdentifier`
public protocol EmbeddingProvider: AnyObject {
    /// An identifier which uniquely identifies the provider/model
    var embeddingModelIdentifier: String { get set }

    /// A `Vector` embedding for a given text
    func embedding(for text: String) async throws -> Vector?

    /// A `Vector` embedding for a given text, in a known `role`. Has a default
    /// that prepends the model's documented task-instruction prefix when
    /// `embeddingModelIdentifier` names a known instruction-tuned family
    /// (see ``EmbeddingTaskPrefix/forModel(_:)``) and embeds symmetrically
    /// otherwise, so existing providers need not implement it; a provider can
    /// override it to apply a custom query vs. document prompt template.
    func embedding(for text: String, role: EmbeddingRole) async throws -> Vector?
}

public extension EmbeddingProvider {
    func embedding(for text: String, role: EmbeddingRole) async throws -> Vector? {
        guard let prefix = EmbeddingTaskPrefix.forModel(embeddingModelIdentifier) else {
            return try await embedding(for: text)
        }
        return try await embedding(for: prefix.apply(to: text, role: role))
    }
}
