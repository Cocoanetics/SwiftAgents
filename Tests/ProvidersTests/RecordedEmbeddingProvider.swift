//
//  RecordedEmbeddingProvider.swift
//  SwiftAgents
//
//  An `EmbeddingProvider` that replays embeddings recorded from a real provider
//  (OpenAI `text-embedding-3-small`) instead of calling one live. The vectors
//  live in the `recorded_openai_embeddings.json` fixture; regenerate them with
//  `scripts/record-embeddings.py`.
//
//  This lets the semantic-search tests run deterministically with real
//  embedding geometry — no API key, on every platform — for both the
//  brute-force `LocalVectorStore` and the SQLite-backed store. It is a plain
//  test helper (not gated by any trait), so both suites can share it.
//

import Foundation
import Providers

final class RecordedEmbeddingProvider: EmbeddingProvider {
    var embeddingModelIdentifier = "text-embedding-3-small (recorded)"
    private let table: [String: Vector]

    init() throws {
        let url = try TestResources.url(forResource: "recorded_openai_embeddings", withExtension: "json")
        let data = try Data(contentsOf: url)
        table = try JSONDecoder().decode([String: Vector].self, from: data)
    }

    /// Returns the recorded vector for `text`, normalized to unit length to
    /// match what the live `OpenAI` provider yields (`averageUnitVector`), or
    /// `nil` if the text wasn't recorded.
    func embedding(for text: String) async throws -> Vector? {
        guard let vector = table[text] else { return nil }
        let magnitude = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return magnitude == 0 ? nil : vector.map { $0 / magnitude }
    }
}
