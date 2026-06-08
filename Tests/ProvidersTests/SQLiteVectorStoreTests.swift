//
//  SQLiteVectorStoreTests.swift
//  SwiftAgents
//
//  The SQLite-backed analogue of `LocalVectorStoreTests`, plus coverage for the
//  provenance + incremental-indexing model copied from openclaw: line-aware
//  chunking with line spans, `source:path:start:end` citations, hash-based
//  incremental sync (skip unchanged / prune deleted), and source filtering.
//
//  Gated on the `SQLiteVectorStore` trait — run with:
//      swift test --traits SQLiteVectorStore
//

#if SQLiteVectorStore

import Foundation
@testable import Providers
import Testing
@testable import VectorStore

struct SQLiteVectorStoreTests {
    /// Deterministic embedder: a fixed unit vector per known phrase (or a
    /// shared fallback), plus a call counter so incremental tests can prove a
    /// file was *not* re-embedded.
    private final class StubEmbeddingProvider: EmbeddingProvider {
        var embeddingModelIdentifier = "stub-test-embedder"
        private(set) var callCount = 0
        private let table: [String: Vector]
        private let fallback: Vector?

        init(table: [String: Vector] = [:], fallback: Vector? = nil) {
            self.table = table
            self.fallback = fallback
        }

        func embedding(for text: String) async throws -> Vector? {
            callCount += 1
            return (table[text] ?? fallback)?.unitVector()
        }
    }

    private static func tempPath(_ ext: String = "md") -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("svs-\(UUID().uuidString).\(ext)").path
    }

    // MARK: - Chunker

    @Test("line chunker tracks 1-indexed source line spans")
    func lineChunkerTracksLineSpans() {
        // maxChars floors at 32 (openclaw's `max(32, …)`); two ~14-char lines
        // fit per chunk, the third tips over.
        let content = "one two three\nfour five six\nseven eight\nnine ten"
        let chunks = LineChunker.chunk(content, maxChars: 32, overlapChars: 0)

        #expect(chunks.map(\.startLine) == [1, 3])
        #expect(chunks.map(\.endLine) == [2, 4])
        #expect(chunks[0].text == "one two three\nfour five six")
        #expect(chunks[1].text == "seven eight\nnine ten")
    }

    @Test("line chunker overlaps consecutive chunks")
    func lineChunkerOverlapsChunks() {
        let content = (1 ... 8).map { "line number \($0) here" }.joined(separator: "\n")
        let chunks = LineChunker.chunk(content, maxChars: 32, overlapChars: 16)

        #expect(chunks.count >= 2)
        #expect(chunks.first?.startLine == 1)
        #expect(chunks.last?.endLine == 8)
        // Overlap: each chunk begins at or before the previous chunk's last line.
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(next.startLine <= previous.endLine)
        }
    }

    // MARK: - Vector search (offline)

    @Test("vec0 KNN ranks the nearest chunk first")
    func vectorSearchRanksNearest() async throws {
        let store = try SQLiteVectorStore(embeddingProvider: StubEmbeddingProvider(table: [
            "cat": [1, 0, 0, 0],
            "car": [0, 1, 0, 0],
            "sky": [0, 0, 1, 0],
            "dog": [0.8, 0.2, 0, 0],
            "a small purring pet": [0.9, 0.1, 0, 0]
        ]))
        for word in ["cat", "car", "sky", "dog"] {
            try await store.indexText(word, path: "\(word).txt")
        }
        #expect(try store.count() == 4)

        let results = try await store.search(text: "a small purring pet", topN: 2)
        #expect(results.map(\.path) == ["cat.txt", "dog.txt"])
        #expect(results[0].score > results[1].score)
        #expect(results[0].score > 0.99)
    }

    @Test("mismatched embedding dimension is rejected")
    func dimensionGuard() async throws {
        let store = try SQLiteVectorStore(embeddingProvider: StubEmbeddingProvider(table: [
            "a": [1, 0, 0, 0],
            "b": [1, 0]
        ]))
        try await store.indexText("a", path: "a")
        await #expect(throws: SQLiteVectorStoreError.self) {
            try await store.indexText("b", path: "b")
        }
    }

    // MARK: - Provenance

    @Test("chunks carry path, source, line span, and a citation")
    func provenanceAndCitation() async throws {
        let store = try SQLiteVectorStore(embeddingProvider: StubEmbeddingProvider(fallback: [1, 0, 0, 0]))
        try await store.indexText("alpha\nbeta\ngamma", path: "notes.md", source: "memory")

        let hits = try await store.search(text: "anything", topN: 1)
        let hit = try #require(hits.first)
        #expect(hit.path == "notes.md")
        #expect(hit.source == "memory")
        #expect(hit.startLine == 1)
        #expect(hit.endLine == 3)
        #expect(hit.text == "alpha\nbeta\ngamma")
        #expect(hit.citation == "memory:notes.md:1:3")
    }

    @Test("re-indexing the same path replaces its chunks")
    func reindexReplacesChunks() async throws {
        let store = try SQLiteVectorStore(embeddingProvider: StubEmbeddingProvider(fallback: [1, 0, 0, 0]))
        try await store.indexText("first version", path: "doc.md")
        #expect(try store.count() == 1)

        try await store.indexText("second version entirely", path: "doc.md")
        #expect(try store.count() == 1)                                   // replaced, not appended
        #expect(try store.keywordSearch("first", topN: 5).isEmpty)        // old content gone
        #expect(try store.keywordSearch("second", topN: 5).first?.path == "doc.md")
    }

    // MARK: - Keyword search (offline, FTS5)

    @Test("FTS5 keyword search returns the matching chunk, bm25-ranked")
    func keywordSearchMatches() async throws {
        let store = try SQLiteVectorStore(embeddingProvider: StubEmbeddingProvider(fallback: [0, 0, 0, 1]))
        try await store.indexText("the cat sat on the mat", path: "cat.txt")
        try await store.indexText("a fast car on the open road", path: "car.txt")
        try await store.indexText("grey clouds drift across the sky", path: "sky.txt")

        let hits = try store.keywordSearch("car", topN: 5)
        #expect(hits.count == 1)
        #expect(hits.first?.path == "car.txt")

        let either = try store.keywordSearch("cat OR clouds", topN: 5)
        #expect(Set(either.map(\.path)) == ["cat.txt", "sky.txt"])
    }

    // MARK: - Hybrid search (offline)

    @Test("hybrid fuses vector + keyword and beats either leg alone")
    func hybridFusesVectorAndKeyword() async throws {
        let store = try SQLiteVectorStore(embeddingProvider: StubEmbeddingProvider(table: [
            "ripe banana": [1, 0, 0, 0],            // the query
            "fresh apple juice": [0.85, 0.5, 0, 0], // closest vector, no shared terms
            "ripe banana fruit": [0.8, 0.55, 0, 0], // weaker vector, matches both terms
            "banana bread recipe": [0, 1, 0, 0]     // far vector, matches one term
        ]))
        try await store.indexText("fresh apple juice", path: "apple.txt")
        try await store.indexText("ripe banana fruit", path: "banana.txt")
        try await store.indexText("banana bread recipe", path: "bread.txt")

        let vectorOnly = try await store.search(text: "ripe banana", topN: 1)
        #expect(vectorOnly.first?.path == "apple.txt")

        let hybrid = try await store.hybridSearch(text: "ripe banana", topN: 1)
        #expect(hybrid.first?.path == "banana.txt")
    }

    // MARK: - Incremental sync (offline)

    @Test("indexing a file skips re-embedding when content is unchanged")
    func incrementalSyncSkipsUnchanged() async throws {
        let provider = StubEmbeddingProvider(fallback: [1, 0, 0, 0])
        let store = try SQLiteVectorStore(embeddingProvider: provider)
        let path = Self.tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try "hello world\nsecond line".write(toFile: path, atomically: true, encoding: .utf8)
        let firstOutcome = try await store.indexFile(at: path)
        #expect(firstOutcome == .indexed(chunks: 1))
        let afterFirst = provider.callCount

        // Unchanged → skipped, no embedding calls.
        let secondOutcome = try await store.indexFile(at: path)
        #expect(secondOutcome == .unchanged)
        #expect(provider.callCount == afterFirst)

        // Changed → re-indexed, embedding runs again.
        try "hello world\nsecond line\nthird line added".write(toFile: path, atomically: true, encoding: .utf8)
        let thirdOutcome = try await store.indexFile(at: path)
        #expect(thirdOutcome == .indexed(chunks: 1))
        #expect(provider.callCount > afterFirst)
    }

    @Test("sync prunes chunks for files no longer present")
    func syncPrunesDeletedFiles() async throws {
        let store = try SQLiteVectorStore(embeddingProvider: StubEmbeddingProvider(fallback: [1, 0, 0, 0]))
        let fileA = Self.tempPath()
        let fileB = Self.tempPath()
        defer {
            try? FileManager.default.removeItem(atPath: fileA)
            try? FileManager.default.removeItem(atPath: fileB)
        }
        try "alpha content here".write(toFile: fileA, atomically: true, encoding: .utf8)
        try "beta different text".write(toFile: fileB, atomically: true, encoding: .utf8)

        let first = try await store.sync(files: [fileA, fileB])
        #expect(first.indexed == 2)
        #expect(try store.count() == 2)

        // Drop fileB from the set → it is pruned.
        let second = try await store.sync(files: [fileA])
        #expect(second.unchanged == 1)
        #expect(second.removed == 1)
        #expect(try store.count() == 1)
    }

    // MARK: - Source filtering (offline)

    @Test("search can be scoped to a source")
    func sourceFilterScopesResults() async throws {
        let store = try SQLiteVectorStore(embeddingProvider: StubEmbeddingProvider(fallback: [1, 0, 0, 0]))
        try await store.indexText("a memory note about cats", path: "m.md", source: "memory")
        try await store.indexText("a session note about cats", path: "s.md", source: "sessions")

        let all = try await store.search(text: "cats", topN: 10)
        #expect(Set(all.map(\.source)) == ["memory", "sessions"])

        let onlySessions = try await store.search(text: "cats", topN: 10, sources: ["sessions"])
        #expect(onlySessions.allSatisfy { $0.source == "sessions" })
        #expect(onlySessions.map(\.path) == ["s.md"])
    }

    // MARK: - Persistence (offline)

    @Test("embeddings persist to a file and survive reopening")
    func persistsAcrossReopen() async throws {
        let path = Self.tempPath("sqlite")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let stub = StubEmbeddingProvider(table: [
            "alpha": [1, 0, 0, 0],
            "beta": [0, 1, 0, 0],
            "near alpha": [0.95, 0.05, 0, 0]
        ])
        do {
            let store = try SQLiteVectorStore(storage: .file(path), embeddingProvider: stub)
            try await store.indexText("alpha", path: "alpha.txt")
            try await store.indexText("beta", path: "beta.txt")
            #expect(try store.count() == 2)
        }

        let reopened = try SQLiteVectorStore(storage: .file(path), embeddingProvider: stub)
        #expect(try reopened.count() == 2)
        let results = try await reopened.search(text: "near alpha", topN: 1)
        #expect(results.first?.path == "alpha.txt")
    }

    // MARK: - Apple on-device embeddings (NLContextualEmbedding)

    // Apple-only (`#if canImport(NaturalLanguage)`), so it runs on the macOS CI
    // job and compiles out elsewhere. The first call downloads the on-device
    // asset on a fresh runner, so the CI step that runs this allows extra time.
    #if canImport(NaturalLanguage)
    @Test("Apple on-device NL embeddings drive vec0 search")
    func appleContextualEmbeddings() async throws {
        // No provider passed → on Apple platforms the store uses
        // ContextualEmbeddingProvider (NLContextualEmbedding): on-device, no
        // API key, no model beyond the OS-managed asset.
        let store = try SQLiteVectorStore()
        try await store.indexText("Status Meeting", path: "meeting.txt")
        try await store.indexText("Schulstrasse 3, 2421 Kittsee", path: "address.txt")
        #expect(try store.count() == 2)

        // Same proven pairing as LocalVectorStoreTests: the meeting note is
        // semantically nearer the query than the address.
        let results = try await store.search(text: "A place where people can gather to discuss", topN: 2)
        #expect(results.count == 2)
        #expect(results.first?.path == "meeting.txt")
        #expect(results[0].score > results[1].score)
    }
    #endif

    // MARK: - OpenAI (gated on OPENAI_API_KEY)

    @Test(
        "Semantic search over real OpenAI embeddings",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func openAISemanticSearch() async throws {
        let store = try SQLiteVectorStore(embeddingProvider: try TestClients.openAI())
        for name in ["the_gambler", "vision", "pasching"] {
            let text = try TestResources.text(named: name, withExtension: "txt")
            try await store.indexText(text, path: "\(name).txt")
        }
        let results = try await store.search(text: "When did Leopold Pasching die?", topN: 3)
        #expect(results.prefix(3).contains { $0.path == "pasching.txt" })
    }

    // Deterministic counterpart to the live OpenAI test above: real recorded
    // 1536-d vectors (no key), so the full pipeline — chunk, pack float32,
    // vec0 cosine KNN — runs against real embedding geometry on every platform.
    @Test("Recorded OpenAI embeddings rank by meaning (no key)")
    func recordedOpenAISemanticSearch() async throws {
        let store = try SQLiteVectorStore(embeddingProvider: try RecordedEmbeddingProvider())
        try await store.indexText(
            "Leopold Pasching, an Austrian engineer, died on 13 February 1962 in Vienna.",
            path: "pasching.txt"
        )
        try await store.indexText(
            "The Eiffel Tower is an iron lattice tower on the Champ de Mars in Paris, France.",
            path: "eiffel.txt"
        )
        try await store.indexText(
            "Honeybees communicate the location of nectar to the hive through a waggle dance.",
            path: "bees.txt"
        )
        try await store.indexText(
            "The central bank raised its benchmark interest rate by half a percentage point.",
            path: "bank.txt"
        )
        let results = try await store.search(text: "When did Leopold Pasching die?", topN: 1)
        #expect(results.first?.path == "pasching.txt")
    }
}

#endif
