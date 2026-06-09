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
/// both reference it without pulling the Apple-only `VectorStore`
/// target. The vector-math extensions (cosine similarity, magnitude,
/// average, etc.) live in `VectorStore/Array+Vector.swift` and use
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

/// Protocol for providing embeddings. Gives a `modelIdentifier` for `VectorStore` to identify with which provider
/// embeddings were created.
///  - note: It's based on `AnyObject` so that we can set the `embeddingModelIdentifier`
public protocol EmbeddingProvider: AnyObject {
    /// An identifier which uniquely identifies the provider/model
    var embeddingModelIdentifier: String { get set }

    /// A `Vector` embedding for a given text
    func embedding(for text: String) async throws -> Vector?

    /// A `Vector` embedding for a given text, in a known `role`. Has a default
    /// that ignores `role` (symmetric embedding), so existing providers need not
    /// implement it; an instruction-tuned provider overrides it to apply the
    /// model's query vs. document prompt template.
    func embedding(for text: String, role: EmbeddingRole) async throws -> Vector?
}

public extension EmbeddingProvider {
    func embedding(for text: String, role: EmbeddingRole) async throws -> Vector? {
        try await embedding(for: text)
    }
}
