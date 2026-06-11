//
//  OllamaAPI+EmbeddingProvider.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 19.04.24.
//

import Foundation
import Providers

extension OllamaAPI: EmbeddingProvider {
    public func embedding(for text: String) async throws -> Vector? {
        let embedding = try await embedding(input: text, model: embeddingModelIdentifier)

        return embedding.unitVector()
    }
}
