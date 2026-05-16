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

/// Protocol for providing embeddings. Gives a `modelIdentifier` for `VectorStore` to identify with which provider
/// embeddings were created.
///  - note: It's based on `AnyObject` so that we can set the `embeddingModelIdentifier`
public protocol EmbeddingProvider: AnyObject {
    /// An identifier which uniquely identifies the provider/model
    var embeddingModelIdentifier: String { get set }

    /// A `Vector` embedding for a given text
    func embedding(for text: String) async throws -> Vector?
}
