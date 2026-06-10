//
//  InstructionPrefixEmbeddingProviderTests.swift
//  SwiftAgents
//
//  The decorator is pure string-prefixing + delegation, so these tests use a
//  capturing stub provider (no network, every platform) to assert the right
//  prompt template reaches the wrapped provider per `EmbeddingRole`.
//

import Foundation
import Testing
import Providers

@Suite struct InstructionPrefixEmbeddingProviderTests {

    /// Records the exact text it was asked to embed, so a test can assert the
    /// role prefix was applied before delegation.
    final class CapturingProvider: EmbeddingProvider {
        var embeddingModelIdentifier = "stub"
        var seen: [String] = []
        func embedding(for text: String) async throws -> Vector? {
            seen.append(text)
            return [1, 2, 3]
        }
    }

    @Test func appliesQueryAndDocumentPrefixes() async throws {
        let inner = CapturingProvider()
        let provider = InstructionPrefixEmbeddingProvider(wrapping: inner, template: .embeddinggemma)

        _ = try await provider.embedding(for: "cats", role: .query)
        _ = try await provider.embedding(for: "cats sit on mats", role: .document)

        // Query and document diverge — the asymmetry the model expects.
        #expect(inner.seen == [
            "task: search result | query: cats",
            "title: none | text: cats sit on mats"
        ])
    }

    @Test func qwen3DocumentSideIsRaw() async throws {
        let inner = CapturingProvider()
        let provider = InstructionPrefixEmbeddingProvider(wrapping: inner, template: .qwen3)

        _ = try await provider.embedding(for: "dogs", role: .document)

        #expect(inner.seen == ["dogs"])   // empty document prefix → raw text
    }

    @Test func forwardsModelIdentifier() {
        let inner = CapturingProvider()
        inner.embeddingModelIdentifier = "embeddinggemma:300m"
        let provider = InstructionPrefixEmbeddingProvider(wrapping: inner, template: .embeddinggemma)

        // The wrapped model is what the store records for embed-fingerprinting.
        #expect(provider.embeddingModelIdentifier == "embeddinggemma:300m")
    }

    @Test func matchesKnownFamiliesAndIgnoresSymmetric() {
        typealias Template = InstructionPrefixEmbeddingProvider.Template
        #expect(Template.matching(modelIdentifier: "embeddinggemma:300m")?.queryPrefix
            == "task: search result | query: ")
        #expect(Template.matching(modelIdentifier: "qwen3-embedding:0.6b")?.documentPrefix == "")
        #expect(Template.matching(modelIdentifier: "nomic-embed-text")?.queryPrefix == "search_query: ")
        #expect(Template.matching(modelIdentifier: "text-embedding-3-small") == nil)   // symmetric → unwrapped
    }
}
