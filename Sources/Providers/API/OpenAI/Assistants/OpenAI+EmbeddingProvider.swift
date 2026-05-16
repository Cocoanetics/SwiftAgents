//
//  OpenAIAPI+EmbeddingProvider.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 19.04.24.
//

import Foundation

extension OpenAI: EmbeddingProvider {
	public func embedding(for text: String) async throws -> Vector? {

		let embedding = try await self.embedding(input: text, model: embeddingModelIdentifier)

		let vectors = embedding.map { $0.embedding }
		return vectors.averageUnitVector()
	}
}
