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

    @Test("chunker tracks 1-indexed source line spans")
    func lineChunkerTracksLineSpans() {
        // Budget floors at 32; the best break-point lands after "four five six".
        let content = "one two three\nfour five six\nseven eight\nnine ten"
        let chunks = LineChunker.chunk(content, maxChars: 32, overlapChars: 0)

        #expect(chunks.map(\.startLine) == [1, 3])
        #expect(chunks.map(\.endLine) == [2, 4])
        #expect(chunks[0].text == "one two three\nfour five six")
        #expect(chunks[1].text == "seven eight\nnine ten")
    }

    @Test("chunker overlaps consecutive chunks")
    func chunkerOverlapsChunks() {
        let content = (1 ... 40).map { "Sentence number \($0) with a handful of words." }
            .joined(separator: "\n") + "\n"
        let chunks = LineChunker.chunk(content, maxChars: 200, overlapChars: 60)

        #expect(chunks.count >= 2)
        #expect(chunks.first?.startLine == 1)
        #expect((chunks.last?.endLine ?? 0) >= 40)
        // Overlap: each chunk begins at or before the previous chunk's last line.
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(next.startLine <= previous.endLine)
        }
    }

    @Test("chunker breaks at heading boundaries")
    func chunkerBreaksAtHeadings() {
        func section(_ title: String) -> String {
            "## \(title)\n\n" + String(repeating: "word ", count: 25) + "\n"
        }
        let doc = "# Doc\n\n" + section("Alpha") + "\n" + section("Beta") + "\n" + section("Gamma")
        let chunks = LineChunker.chunk(doc, maxChars: 150, overlapChars: 0, windowChars: 130)

        #expect(chunks.count >= 2)
        // The scored break-points chose a heading boundary over weaker breaks.
        #expect(chunks.dropFirst().contains { $0.text.hasPrefix("## ") })
    }

    @Test("chunker never splits inside a code fence")
    func chunkerProtectsCodeFences() {
        let doc = "Alpha paragraph that is reasonably wordy to take up space here.\n\n"
            + "```\nx = 1\n\ny = 2\n```\n\n"
            + "Omega paragraph that is also reasonably wordy down here.\n"
        let chunks = LineChunker.chunk(doc, maxChars: 70, overlapChars: 0, windowChars: 70)

        let body = chunks.first { $0.text.contains("x = 1") }
        #expect(body?.text.contains("y = 2") == true)
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

    // MARK: - RRF fusion (offline)

    @Test("RRF rewards items that rank across multiple lists")
    func rrfRewardsConsensus() {
        // "b" is the only item in both lists (and tops the second) — it wins.
        let fused = reciprocalRankFusion([
            (items: ["a", "b", "c"], weight: 1.0),
            (items: ["b", "d"], weight: 1.0)
        ])
        #expect(fused.first?.item == "b")
        #expect(Set(fused.map(\.item)) == ["a", "b", "c", "d"])
    }

    @Test("RRF honors per-list weights")
    func rrfHonorsWeights() {
        // Each item tops its own list; the heavier list breaks the tie.
        let fused = reciprocalRankFusion([
            (items: ["heavy"], weight: 2.0),
            (items: ["light"], weight: 1.0)
        ])
        #expect(fused.first?.item == "heavy")
    }

    @Test("fusedSearch merges vector + keyword legs via RRF")
    func fusedSearchMergesLegs() async throws {
        let store = try SQLiteVectorStore(embeddingProvider: StubEmbeddingProvider(table: [
            "ripe banana": [1, 0, 0, 0],            // the query — closest to apple by vector
            "fresh apple juice": [0.85, 0.5, 0, 0], // best vector, no shared terms
            "ripe banana fruit": [0.8, 0.55, 0, 0], // weaker vector, matches both terms
            "banana bread recipe": [0, 1, 0, 0]     // far vector, one shared term
        ]))
        try await store.indexText("fresh apple juice", path: "apple.txt")
        try await store.indexText("ripe banana fruit", path: "banana.txt")
        try await store.indexText("banana bread recipe", path: "bread.txt")

        // The vector leg alone favors apple; fusing the keyword leg via RRF lifts
        // the chunk both legs agree on (banana — matches both query terms) to #1.
        let fused = try await store.fusedSearch(vector: ["ripe banana"], keyword: ["ripe banana"], topN: 1)
        #expect(fused.first?.path == "banana.txt")
    }

    // MARK: - Query expansion (offline)

    /// Records that it was asked, and returns a fixed expansion set.
    private final class SpyExpander: QueryExpander, @unchecked Sendable {
        let expansions: [ExpandedQuery]
        private(set) var callCount = 0
        init(_ expansions: [ExpandedQuery]) { self.expansions = expansions }
        func expand(_ query: String, intent: String?) async throws -> [ExpandedQuery] {
            callCount += 1
            return expansions
        }
    }

    @Test("template expander yields hyde + raw lex/vec")
    func templateExpanderTypedQueries() async throws {
        let expansions = try await TemplateQueryExpander().expand("rotate the key", intent: nil)
        #expect(expansions.contains { $0.kind == .hyde && $0.text == "Information about rotate the key" })
        #expect(expansions.contains { $0.kind == .lex && $0.text == "rotate the key" })
        #expect(expansions.contains { $0.kind == .vec && $0.text == "rotate the key" })
    }

    @Test("expandedSearch surfaces chunks the literal query misses")
    func expandedSearchSurfacesExpansionTargets() async throws {
        let store = try SQLiteVectorStore(embeddingProvider: StubEmbeddingProvider(table: [
            "orig": [1, 0, 0, 0],     // the query — near a/b, orthogonal to c
            "near": [0.9, 0.1, 0, 0],
            "far": [0, 0, 1, 0],      // c
            "exp": [0, 0, 1, 0]       // a vec expansion pointing right at c
        ]))
        try await store.indexText("orig", path: "a.txt")
        try await store.indexText("near", path: "b.txt")
        try await store.indexText("far", path: "c.txt")

        // The literal query's top-2 vectors don't include c (orthogonal).
        let plain = try await store.search(text: "orig", topN: 2)
        #expect(!plain.contains { $0.path == "c.txt" })

        // A vec expansion pointing at c pulls it into the fused top-2.
        let expander = SpyExpander([ExpandedQuery(kind: .vec, text: "exp")])
        let expanded = try await store.expandedSearch(text: "orig", using: expander, topN: 2)
        #expect(expander.callCount == 1)
        #expect(expanded.contains { $0.path == "c.txt" })
    }

    @Test("LLM expander parses typed lines and drops ungrounded ones")
    func llmExpanderParsesGrounds() async throws {
        let expander = LLMQueryExpander { _ in
            """
            lex: rotate key
            vec: how do I rotate the api key
            hyde: To rotate the key, open settings and generate a new one.
            vec: completely unrelated gibberish
            """
        }
        let result = try await expander.expand("rotate key", intent: nil)
        #expect(result.contains { $0.kind == .lex && $0.text == "rotate key" })
        #expect(result.contains { $0.kind == .hyde })
        // Shares no term with "rotate key" → the grounding filter drops it.
        #expect(!result.contains { $0.text.contains("gibberish") })
    }

    @Test("LLM expander falls back to the template on an empty response")
    func llmExpanderFallback() async throws {
        let expander = LLMQueryExpander { _ in "" }
        let result = try await expander.expand("hello world", intent: nil)
        #expect(result.contains { $0.kind == .hyde && $0.text == "Information about hello world" })
    }

    @Test("strong-signal gating skips expansion when confident")
    func strongSignalGatingSkips() async throws {
        let store = try SQLiteVectorStore(embeddingProvider: StubEmbeddingProvider(fallback: [1, 0, 0, 0]))
        try await store.indexText("xyzzy plugh frobozz", path: "doc.txt")

        // A zero threshold makes any keyword hit "strong" → expansion is skipped.
        let gated = SpyExpander([ExpandedQuery(kind: .vec, text: "xyzzy")])
        let results = try await store.expandedSearch(
            text: "xyzzy", using: gated, topN: 5, strongSignalMinScore: 0, strongSignalMinGap: 0)
        #expect(gated.callCount == 0)
        #expect(results.contains { $0.path == "doc.txt" })

        // Gating disabled → the expander runs.
        let ungated = SpyExpander([ExpandedQuery(kind: .vec, text: "xyzzy")])
        _ = try await store.expandedSearch(text: "xyzzy", using: ungated, topN: 5, strongSignalGating: false)
        #expect(ungated.callCount == 1)
    }

    // MARK: - Reranking (offline)

    @Test("rerank blends reranker score with fusion position")
    func rerankBlendsWithPosition() async throws {
        let store = try SQLiteVectorStore(embeddingProvider: StubEmbeddingProvider(table: [
            "alpha": [1, 0, 0, 0], "beta": [0.9, 0.1, 0, 0], "gamma": [0.8, 0.2, 0, 0]
        ]))
        try await store.indexText("alpha", path: "a.txt")
        try await store.indexText("beta", path: "b.txt")
        try await store.indexText("gamma", path: "c.txt")

        let fused = try await store.fusedSearch(vector: ["alpha"], keyword: [], topN: 3)
        #expect(fused.map(\.path) == ["a.txt", "b.txt", "c.txt"])

        // A reranker that loves the last candidate (gamma/c) lifts it above b —
        // but a's strong fusion position keeps it on top.
        let reranker = LLMReranker { _, document in document == "gamma" ? 0.9 : 0.1 }
        let reranked = try await store.rerank(query: "alpha", candidates: fused, using: reranker)
        #expect(reranked.map(\.path) == ["a.txt", "c.txt", "b.txt"])
    }

    @Test("LLM reranker prepends intent to the query")
    func llmRerankerPrependsIntent() async throws {
        // Scores 1 only when the rerank query carries the intent prefix.
        let reranker = LLMReranker { query, _ in query.contains("billing context") ? 1 : 0 }
        let withIntent = try await reranker.scores(query: "refund", candidates: ["doc"], intent: "billing context")
        let without = try await reranker.scores(query: "refund", candidates: ["doc"], intent: nil)
        #expect(withIntent == [1])
        #expect(without == [0])
    }

    // MARK: - Embedding role (offline)

    /// Records the role of the last embedding call; overrides the role-aware
    /// method so the store's dispatch can be observed.
    private final class RoleStubEmbeddingProvider: EmbeddingProvider {
        var embeddingModelIdentifier = "role-stub"
        private(set) var lastRole: EmbeddingRole?
        func embedding(for text: String) async throws -> Vector? { [1, 0, 0, 0] }
        func embedding(for text: String, role: EmbeddingRole) async throws -> Vector? {
            lastRole = role
            return role == .document ? [1, 0, 0, 0] : [0, 1, 0, 0]
        }
    }

    @Test("the store embeds documents on index and queries on search")
    func embeddingRoleApplied() async throws {
        let provider = RoleStubEmbeddingProvider()
        let store = try SQLiteVectorStore(embeddingProvider: provider)

        try await store.indexText("a document", path: "d.txt")
        #expect(provider.lastRole == .document)

        _ = try await store.search(text: "a query", topN: 1)
        #expect(provider.lastRole == .query)
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
