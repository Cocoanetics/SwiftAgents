//
//  EmbeddingsGenerator.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 18.04.24.
//

import NaturalLanguage
import Foundation

enum EmbeddingsModelError: Error {
	case unknownLanguage
	case noModelAvailableForLanguage
}

/// A built-in embedding provider using `NLContextualEmbedding`. This is multi-language where languages of the same script (e.g. Latin) whare one model.
public class ContextualEmbeddingProvider {
	public var embeddingModelIdentifier: String = "AppleContextualEmbeddingProvider"

	/// lookup table to map language to model
	private var embeddingsCache: [NLLanguage: NLContextualEmbedding] = [:]

	public init() {

	}

	internal func embeddingVector(for text: String, language: NLLanguage? = nil) async throws -> Vector? {

		guard let language = language ?? NLLanguageRecognizer.dominantLanguage(for: text) else {
			throw EmbeddingsModelError.unknownLanguage
		}

		let model = try await self.model(for: language)

		return calculateAverageVector(from: model, for: text)
	}

	private func model(for language: NLLanguage) async throws -> NLContextualEmbedding {
		let embedding: NLContextualEmbedding

		if let cached = embeddingsCache[language] {
			embedding = cached
		} else if let newEmbedding = NLContextualEmbedding(language: language) {

			// might need to download model first
			if !newEmbedding.hasAvailableAssets {
				try await requestAssets(for: newEmbedding)
			}

			try newEmbedding.load()

			// cache same NSObject for all supported languages
			newEmbedding.languages.forEach { embeddingsCache[$0] = newEmbedding }

			embedding = newEmbedding

		} else {
			throw EmbeddingsModelError.noModelAvailableForLanguage
		}

		return embedding
	}

	private func requestAssets(for embedding: NLContextualEmbedding) async throws {
		return try await withCheckedThrowingContinuation { continuation in
			embedding.requestAssets { _, error in
				if let error = error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume(returning: ()) // Explicitly returning Void
				}
			}
		}
	}

	private func calculateAverageVector(from embedding: NLContextualEmbedding, for text: String, language: NLLanguage = .english) -> Vector? {
		guard let result = try? embedding.embeddingResult(for: text, language: language) else {
			return nil
		}

		var vectors: [Vector] = []

		result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
			vectors.append(vector)
			return true
		}

		return vectors.averageUnitVector()
	}
}

extension ContextualEmbeddingProvider: EmbeddingProvider {
	public func embedding(for text: String) async throws -> Vector? {
		// return vector created by auto-selected model
		try await embeddingVector(for: text)
	}
}
