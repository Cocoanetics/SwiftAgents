//
//  EmbeddingBenchmarkTests.swift
//  SwiftAgents
//
//  Cross-provider retrieval benchmark over the Canon-style wiki corpus:
//  every reachable embedding model (Apple on-device, OpenAI, Gemini,
//  LM Studio) indexes the same ten markdown pages into a fresh
//  `SQLiteVectorStore`, then answers ten English queries through all
//  three search modes — `keywordSearch` (FTS5 bm25 only), `search`
//  (vec0 cosine only), and `hybridSearch` (0.7/0.3 blend) — recording
//  accuracy (top-1, MRR) and per-query latency for each mode, so the
//  modes can be charted against each other per model.
//
//  (The earlier role-aware vs. bare prefix comparison lives at commit
//  e2c0a31 if it needs re-running.)
//
//  Deliberately NOT part of any normal test run: gated on EMBED_BENCHMARK.
//  Results are written as JSON for report/chart generation:
//      EMBED_BENCHMARK=1 swift test --traits SQLiteVectorStore \
//          --filter EmbeddingBenchmarkTests
//      output: $EMBED_BENCHMARK_OUT or /tmp/embedding-benchmark.json
//

#if SQLiteVectorStore

import Foundation
@testable import Providers
import Testing
@testable import VectorStore

struct EmbeddingBenchmarkTests {
    // MARK: - Corpus

    private static let wiki: [(path: String, text: String)] = [
        (
            path: "Characters/Stormy.md",
            text: """
            # Stormy

            Stormy is a brave little dragon who lives in the old lighthouse above the
            cliffs. She breathes careful puffs of fire to relight the beacon whenever
            winter gales blow it out, and the fishing crews trust her to guide them home.
            """
        ),
        (
            path: "Characters/Nimbus.md",
            text: """
            # Nimbus

            Nimbus is a cloud spirit who drifts over the islands and gathers rain for
            the terraced gardens. He speaks in soft thunder, naps inside fog banks, and
            refuses to rain on festival days.
            """
        ),
        (
            path: "Characters/Bramble.md",
            text: """
            # Bramble

            Bramble is a hedgehog who keeps the cliff-top garden. She dries herbs in
            her burrow, brews bitter teas for fevers, and trades poultices for stories
            at the market. Her spines collect dandelion fluff in spring.
            """
        ),
        (
            path: "Characters/Vesper.md",
            text: """
            # Vesper

            Vesper is an owl who minds the night archive beneath the bell tower. He
            sorts scrolls and ledgers by candlelight and remembers where every record
            rests, even the ones nobody has asked about in a century.
            """
        ),
        (
            path: "Places/Saltmere.md",
            text: """
            # Saltmere

            Saltmere is a harbor town built on stilts over the tide flats. Boats unload
            herring and kelp at the morning market, and the smell of salt and tar hangs
            over the boardwalks all year.
            """
        ),
        (
            path: "Places/Emberforge.md",
            text: """
            # Emberforge

            Emberforge is a town built around a volcanic vent. Its smiths hammer
            blades and shields through the night, and the clang of anvils echoes
            down the lava-warmed streets.
            """
        ),
        (
            path: "Places/Gloamwood.md",
            text: """
            # Gloamwood

            The Gloamwood is a forest where daylight never quite arrives. Lantern-capped
            mushrooms glimmer beneath the black boughs, travellers mark their paths with
            chalk, and the rare Morrowseed fern grows only where nobody is looking.
            """
        ),
        (
            path: "Lore/Shardfall.md",
            text: """
            # The Shardfall

            When the great crystal called the Vexglass shattered, its corrupted shards
            rained across the isles. Each shard whispers to whoever holds it, so the
            wardens seal every recovered fragment inside lead-lined chests.
            """
        ),
        (
            path: "Lore/Tidesong.md",
            text: """
            # The Tidesong

            The Tidesong is an old hymn the sailors sing when storms rise. Its slow
            verses still the swells around the hull, and harbor children learn it
            before they learn to swim.
            """
        ),
        (
            path: "Lore/Wardenpact.md",
            text: """
            # The Wardenpact

            The Wardenpact is the ancient accord between the island wardens and the
            sea spirits: no nets beyond the third sandbar, and no storms past the
            harbor wall. Both sides have kept it for nine hundred years.
            """
        )
    ]

    private struct BenchQuery {
        let text: String
        let expected: String
        let kind: String
    }

    /// English-only query set: semantic paraphrases (no content-word overlap
    /// with the target), exact rare keywords, and mixed phrasings.
    private static let queries: [BenchQuery] = [
        BenchQuery(text: "a courageous wyrm", expected: "Characters/Stormy.md", kind: "semantic"),
        BenchQuery(text: "where do fishermen sell their catch", expected: "Places/Saltmere.md", kind: "semantic"),
        BenchQuery(
            text: "a prickly little healer who looks after plants",
            expected: "Characters/Bramble.md", kind: "semantic"
        ),
        BenchQuery(text: "who hammers out weapons for warriors", expected: "Places/Emberforge.md", kind: "semantic"),
        BenchQuery(text: "a melody that soothes rough seas", expected: "Lore/Tidesong.md", kind: "semantic"),
        BenchQuery(text: "a wise bird who keeps old books", expected: "Characters/Vesper.md", kind: "semantic"),
        BenchQuery(text: "Vexglass", expected: "Lore/Shardfall.md", kind: "keyword"),
        BenchQuery(text: "Morrowseed", expected: "Places/Gloamwood.md", kind: "keyword"),
        BenchQuery(text: "glowing mushrooms in a dark forest", expected: "Places/Gloamwood.md", kind: "mixed"),
        BenchQuery(text: "the treaty with the sea spirits", expected: "Lore/Wardenpact.md", kind: "mixed")
    ]

    // MARK: - Output shape

    private struct QueryResult: Codable {
        let query: String
        let kind: String
        let expected: String
        let topPath: String
        let rank: Int     // 1-based rank of the expected page; 0 = absent
        let millis: Double
    }

    private struct ModeResult: Codable {
        let mode: String  // "fts" | "vector" | "hybrid"
        var top1 = 0
        var queryCount = 0
        var mrr = 0.0
        var meanQueryMs = 0.0
        var queries: [QueryResult] = []
    }

    private struct RunResult: Codable {
        let model: String
        let provider: String
        var indexSeconds = 0.0
        var modes: [ModeResult] = []
        var error: String?
    }

    // MARK: - Provider wrapper

    /// Retries transient API failures so one 429 doesn't void a whole run.
    private final class RetryingEmbeddingProvider: EmbeddingProvider {
        private let base: any EmbeddingProvider
        var embeddingModelIdentifier: String {
            get { base.embeddingModelIdentifier }
            set { base.embeddingModelIdentifier = newValue }
        }

        init(_ base: any EmbeddingProvider) {
            self.base = base
        }

        func embedding(for text: String) async throws -> Vector? {
            try await attempt { try await self.base.embedding(for: text) }
        }

        func embedding(for text: String, role: EmbeddingRole) async throws -> Vector? {
            try await attempt { try await self.base.embedding(for: text, role: role) }
        }

        private func attempt(_ operation: () async throws -> Vector?) async throws -> Vector? {
            var lastError: Error?
            for round in 0 ..< 3 {
                do {
                    return try await operation()
                } catch {
                    lastError = error
                    try? await Task.sleep(for: .seconds(1.5 * Double(round + 1)))
                }
            }
            throw lastError ?? APIError.invalidResponse
        }
    }

    // MARK: - Benchmark

    @Test(
        "Benchmark all reachable embedding models",
        .enabled(
            if: ProcessInfo.processInfo.environment["EMBED_BENCHMARK"] != nil,
            "Set EMBED_BENCHMARK=1 — live, slow, multi-provider"
        )
    )
    func benchmarkAllModels() async throws {
        var runs: [RunResult] = []
        for candidate in try await availableCandidates() {
            runs.append(await runBenchmark(
                model: candidate.model,
                provider: candidate.kind,
                embeddingProvider: RetryingEmbeddingProvider(candidate.provider)
            ))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let out = ProcessInfo.processInfo.environment["EMBED_BENCHMARK_OUT"]
            ?? "/tmp/embedding-benchmark.json"
        try (try encoder.encode(runs)).write(to: URL(fileURLWithPath: out))
        print("EMBED_BENCHMARK: wrote \(runs.count) runs to \(out)")
        #expect(!runs.isEmpty)
    }

    // MARK: - Candidates

    private struct Candidate {
        let model: String
        let kind: String
        let provider: any EmbeddingProvider
    }

    private func availableCandidates() async throws -> [Candidate] {
        var candidates: [Candidate] = []

        #if canImport(NaturalLanguage)
        if ProcessInfo.processInfo.environment["CI"] == nil {
            candidates.append(Candidate(
                model: "AppleContextualEmbedding", kind: "apple",
                provider: ContextualEmbeddingProvider()
            ))
        }
        #endif

        if APIKey.hasOpenAI {
            for model in ["text-embedding-3-small", "text-embedding-3-large"] {
                let client = try TestClients.openAI()
                client.embeddingModelIdentifier = model
                candidates.append(Candidate(model: model, kind: "openai", provider: client))
            }
        }

        if APIKey.hasGemini {
            for model in ["gemini-embedding-2", "gemini-embedding-001"] {
                let client = try TestClients.google()
                client.embeddingModelIdentifier = model
                candidates.append(Candidate(model: model, kind: "gemini", provider: client))
            }
        }

        if TestClients.hasLMStudio, let client = try? TestClients.lmStudio(),
           let served = try? await client.models().map(\.id) {
            // bge-reranker also advertises an embedding id but is a reranker —
            // embedding with it would be misuse — and modernbert-embed-base is
            // listed but unservable (safetensors only; LM Studio 400s on it),
            // so both are deliberately absent.
            let wanted = [
                "text-embedding-nomic-embed-text-v1.5",
                "text-embedding-nomic-embed-text-v2-moe",
                "text-embedding-embeddinggemma-300m-qat",
                "text-embedding-qwen3-embedding-0.6b",
                "text-embedding-mxbai-embed-large-v1"
            ]
            for model in wanted where served.contains(model) {
                let lmStudio = try TestClients.lmStudio()
                lmStudio.embeddingModelIdentifier = model
                candidates.append(Candidate(model: model, kind: "lmstudio", provider: lmStudio))
            }
        }

        return candidates
    }

    // MARK: - Single run

    private func runBenchmark(
        model: String,
        provider: String,
        embeddingProvider: any EmbeddingProvider
    ) async -> RunResult {
        var run = RunResult(model: model, provider: provider)
        do {
            let store = try SQLiteVectorStore(embeddingProvider: embeddingProvider)

            let indexStart = Date()
            for page in Self.wiki {
                try await store.indexText(page.text, path: page.path, source: "wiki")
            }
            run.indexSeconds = Date().timeIntervalSince(indexStart)

            let topN = Self.wiki.count
            run.modes = try await [
                measureMode("fts") { try store.keywordSearch($0, topN: topN) },
                measureMode("vector") { try await store.search(text: $0, topN: topN) },
                measureMode("hybrid") { try await store.hybridSearch(text: $0, topN: topN) }
            ]
        } catch {
            run.error = "\(error)"
        }
        return run
    }

    private func measureMode(
        _ mode: String,
        _ search: (String) async throws -> [MemoryMatch]
    ) async rethrows -> ModeResult {
        var result = ModeResult(mode: mode)
        var ranks: [Int] = []
        var totalMs = 0.0
        for query in Self.queries {
            let start = Date()
            let hits = try await search(query.text)
            let millis = Date().timeIntervalSince(start) * 1000
            totalMs += millis

            let rank = (hits.firstIndex { $0.path == query.expected }).map { $0 + 1 } ?? 0
            ranks.append(rank)
            result.queries.append(QueryResult(
                query: query.text, kind: query.kind, expected: query.expected,
                topPath: hits.first?.path ?? "", rank: rank, millis: millis
            ))
        }
        result.queryCount = ranks.count
        result.top1 = ranks.filter { $0 == 1 }.count
        result.mrr = ranks.map { $0 > 0 ? 1.0 / Double($0) : 0 }.reduce(0, +) / Double(ranks.count)
        result.meanQueryMs = totalMs / Double(ranks.count)
        return result
    }
}

#endif
