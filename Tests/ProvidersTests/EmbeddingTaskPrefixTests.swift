//
//  EmbeddingTaskPrefixTests.swift
//  SwiftAgents
//
//  Offline coverage for task-instruction prefixes on the role-aware
//  embedding path: the family table, prefix application, and the
//  `EmbeddingProvider` default that wires the two together. The live
//  counterpart is `HybridSearchLiveTests`, where nomic models on LM Studio
//  retrieve through the same default.
//

import Foundation
@testable import Providers
import Testing

struct EmbeddingTaskPrefixTests {
    /// Doesn't override the role-aware method, so the protocol's default
    /// implementation runs — recording the text that finally reaches the
    /// symmetric entry point.
    private final class SpyEmbeddingProvider: EmbeddingProvider {
        var embeddingModelIdentifier: String
        private(set) var lastText: String?

        init(model: String) {
            embeddingModelIdentifier = model
        }

        func embedding(for text: String) async throws -> Vector? {
            lastText = text
            return [1, 0]
        }
    }

    @Test("known instruction-tuned families resolve across provider id forms")
    func familyTableResolves() {
        let nomic = EmbeddingTaskPrefix(query: "search_query: ", document: "search_document: ")
        // LM Studio, Ollama, and bare Hugging Face id forms all hit the family.
        #expect(EmbeddingTaskPrefix.forModel("text-embedding-nomic-embed-text-v1.5") == nomic)
        #expect(EmbeddingTaskPrefix.forModel("text-embedding-nomic-embed-text-v2-moe") == nomic)
        #expect(EmbeddingTaskPrefix.forModel("nomic-embed-text:latest") == nomic)

        let gemma = EmbeddingTaskPrefix(query: "task: search result | query: ", document: "title: none | text: ")
        #expect(EmbeddingTaskPrefix.forModel("text-embedding-embeddinggemma-300m-qat") == gemma)
        #expect(EmbeddingTaskPrefix.forModel("embeddinggemma-300m") == gemma)
    }

    @Test("qwen3-embedding instructs queries and embeds documents raw")
    func qwen3AsymmetricPrefixes() throws {
        let prefix = try #require(EmbeddingTaskPrefix.forModel("text-embedding-qwen3-embedding-0.6b"))
        #expect(EmbeddingTaskPrefix.forModel("qwen3-embedding:4b") == prefix)

        let query = prefix.apply(to: "hello", role: .query)
        #expect(query.hasPrefix("Instruct: "))
        #expect(query.hasSuffix("\nQuery: hello"))
        // Documents carry no prefix — and the empty document marker must not
        // disable query prefixing (every string "starts with" an empty prefix).
        #expect(prefix.apply(to: "hello", role: .document) == "hello")
    }

    @Test("symmetric models match no family")
    func symmetricModelsUnprefixed() {
        #expect(EmbeddingTaskPrefix.forModel("text-embedding-3-small") == nil)
        #expect(EmbeddingTaskPrefix.forModel("text-embedding-3-large") == nil)
        #expect(EmbeddingTaskPrefix.forModel("AppleContextualEmbeddingProvider") == nil)
        #expect(EmbeddingTaskPrefix.forModel("stub-test-embedder") == nil)
    }

    @Test("apply prepends the prefix matching the role")
    func applyMatchesRole() {
        let prefix = EmbeddingTaskPrefix(query: "search_query: ", document: "search_document: ")
        #expect(prefix.apply(to: "hello", role: .query) == "search_query: hello")
        #expect(prefix.apply(to: "hello", role: .document) == "search_document: hello")
    }

    @Test("apply leaves already-prefixed text alone")
    func applySkipsDoublePrefix() {
        let prefix = EmbeddingTaskPrefix(query: "search_query: ", document: "search_document: ")
        #expect(prefix.apply(to: "search_query: hello", role: .query) == "search_query: hello")
        // A manually document-prefixed text isn't re-prefixed as a query either.
        #expect(prefix.apply(to: "search_document: hello", role: .query) == "search_document: hello")
    }

    @Test("the default role-aware path prefixes instruction-tuned models per role")
    func defaultPathPrefixesKnownModels() async throws {
        let spy = SpyEmbeddingProvider(model: "text-embedding-nomic-embed-text-v2-moe")

        _ = try await spy.embedding(for: "a courageous wyrm", role: .query)
        #expect(spy.lastText == "search_query: a courageous wyrm")

        _ = try await spy.embedding(for: "Stormy is a brave little dragon.", role: .document)
        #expect(spy.lastText == "search_document: Stormy is a brave little dragon.")
    }

    @Test("the default role-aware path leaves symmetric models untouched")
    func defaultPathPassesSymmetricModelsThrough() async throws {
        let spy = SpyEmbeddingProvider(model: "text-embedding-3-small")

        _ = try await spy.embedding(for: "a courageous wyrm", role: .query)
        #expect(spy.lastText == "a courageous wyrm")

        _ = try await spy.embedding(for: "a courageous wyrm", role: .document)
        #expect(spy.lastText == "a courageous wyrm")
    }
}
