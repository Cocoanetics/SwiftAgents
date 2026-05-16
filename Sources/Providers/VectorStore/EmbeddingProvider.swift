//
//  EmbeddingProvider.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 19.04.24.
//

import Foundation

/// Protocol for providing embeddings. Gives a `modelIdentifier` for `VectorStore` to identify with which provider embeddings were created.
///  - note: It's based on `AnyObject` so that we can set the `embeddingModelIdentifier`
public protocol EmbeddingProvider: AnyObject {
	/// An identifier which uniquely identifies the provider/model
	var embeddingModelIdentifier: String { get set }

	/// A `Vector` embedding for a given text
	func embedding(for text: String) async throws -> Vector?
}
