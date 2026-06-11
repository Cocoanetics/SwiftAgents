//
//  ContextualEmbeddingProvider.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 18.04.24.
//

#if canImport(NaturalLanguage)

import Foundation
import NaturalLanguage
import Providers

enum EmbeddingsModelError: Error {
    case noModelAvailableForLanguage
}

/// A built-in embedding provider using `NLContextualEmbedding`. This is multi-language where languages of the same
/// script (e.g. Latin) share one model.
public class ContextualEmbeddingProvider {
    public var embeddingModelIdentifier: String = "AppleContextualEmbeddingProvider"

    /// lookup table to map language to model
    private var embeddingsCache: [NLLanguage: NLContextualEmbedding] = [:]

    public init() {}

    /// The user's preferred language. Used when the text is too short or
    /// ambiguous for `NLLanguageRecognizer` to detect one (e.g. a one-word
    /// query), so such text still embeds instead of failing.
    static var systemLanguage: NLLanguage {
        if let code = Locale.current.language.languageCode?.identifier {
            return NLLanguage(code)
        }
        return .english
    }

    func embeddingVector(for text: String, language: NLLanguage? = nil) async throws -> Vector? {
        // NLLanguageRecognizer returns nil for very short / ambiguous text, so
        // fall back to the system language. `model(for:)` falls back further to
        // English if the resolved language has no installed model.
        let preferred = language ?? NLLanguageRecognizer.dominantLanguage(for: text) ?? Self.systemLanguage

        let (embedding, modelLanguage) = try await model(for: preferred)

        return calculateAverageVector(from: embedding, for: text, language: modelLanguage)
    }

    /// Loads (and caches) an `NLContextualEmbedding`, preferring `language` and
    /// falling back to the system language then English, so a missing or
    /// mis-detected language still yields a usable model. Returns the model and
    /// the language it was loaded for (one the model is guaranteed to support).
    private func model(for language: NLLanguage) async throws -> (NLContextualEmbedding, NLLanguage) {
        var tried: Set<NLLanguage> = []
        for candidate in [language, Self.systemLanguage, .english] where tried.insert(candidate).inserted {
            if let cached = embeddingsCache[candidate] {
                return (cached, candidate)
            }
            guard let newEmbedding = NLContextualEmbedding(language: candidate) else {
                continue
            }
            // might need to download model first
            if !newEmbedding.hasAvailableAssets {
                try await requestAssets(for: newEmbedding)
            }

            try newEmbedding.load()

            // cache same NSObject for all supported languages
            newEmbedding.languages.forEach { embeddingsCache[$0] = newEmbedding }

            return (newEmbedding, candidate)
        }

        throw EmbeddingsModelError.noModelAvailableForLanguage
    }

    private func requestAssets(for embedding: NLContextualEmbedding) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            embedding.requestAssets { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ()) // Explicitly returning Void
                }
            }
        }
    }

    private func calculateAverageVector(
        from embedding: NLContextualEmbedding,
        for text: String,
        language: NLLanguage = .english
    ) -> Vector? {
        guard let result = try? embedding.embeddingResult(for: text, language: language) else {
            return nil
        }

        var vectors: [Vector] = []

        result.enumerateTokenVectors(in: text.startIndex ..< text.endIndex) { vector, _ in
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

#endif
