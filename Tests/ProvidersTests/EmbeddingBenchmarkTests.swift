//
//  EmbeddingBenchmarkTests.swift
//  SwiftAgents
//
//  Cross-provider retrieval benchmark over the Canon-style wiki corpus:
//  every reachable embedding model (Apple on-device, OpenAI, Gemini,
//  LM Studio) indexes the same ten markdown pages into a fresh
//  `SQLiteVectorStore` and answers twelve hybrid-search queries — semantic
//  paraphrases, exact rare keywords, German cross-lingual, and mixed.
//  Models with role behavior run twice (role-aware vs. forced-symmetric)
//  so the effect of task prefixes / task types is measurable, and a probe
//  cosine verifies the role-aware path actually changes the embedding.
//
//  Deliberately NOT part of any normal test run: gated on EMBED_BENCHMARK.
//  Results are written as JSON for report generation:
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
        BenchQuery(text: "ein tapferer kleiner Drache", expected: "Characters/Stormy.md", kind: "german"),
        BenchQuery(text: "Wo verkaufen Fischer ihren Fang?", expected: "Places/Saltmere.md", kind: "german"),
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
        let gap: Double   // top score − runner-up score
    }

    private struct RunResult: Codable {
        let model: String
        let provider: String
        let mode: String  // "role-aware" | "bare"
        let prefixFamily: Bool
        var prefixProbeCosine: Double?
        var indexSeconds = 0.0
        var meanQuerySeconds = 0.0
        var top1 = 0
        var queryCount = 0
        var mrr = 0.0
        var meanGapOnCorrect = 0.0
        var error: String?
        var queries: [QueryResult] = []
    }

    // MARK: - Provider wrappers

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

    /// Forces the symmetric path: the "bare" leg of the comparison, embedding
    /// every text without role prefixes or task types.
    private final class SymmetricOnlyProvider: EmbeddingProvider {
        private let base: any EmbeddingProvider
        var embeddingModelIdentifier: String {
            get { base.embeddingModelIdentifier }
            set { base.embeddingModelIdentifier = newValue }
        }

        init(_ base: any EmbeddingProvider) {
            self.base = base
        }

        func embedding(for text: String) async throws -> Vector? {
            try await base.embedding(for: text)
        }

        func embedding(for text: String, role: EmbeddingRole) async throws -> Vector? {
            try await base.embedding(for: text)
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
            let provider = RetryingEmbeddingProvider(candidate.provider)
            let hasRoleBehavior = EmbeddingTaskPrefix.forModel(candidate.model) != nil
                || candidate.model.contains("gemini-embedding-001")

            var roleAware = await runBenchmark(
                model: candidate.model, provider: candidate.kind,
                mode: "role-aware", prefixFamily: hasRoleBehavior,
                embeddingProvider: provider
            )
            roleAware.prefixProbeCosine = await probeCosine(provider)
            runs.append(roleAware)

            if hasRoleBehavior {
                runs.append(await runBenchmark(
                    model: candidate.model, provider: candidate.kind,
                    mode: "bare", prefixFamily: true,
                    embeddingProvider: SymmetricOnlyProvider(provider)
                ))
            }
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
        mode: String,
        prefixFamily: Bool,
        embeddingProvider: any EmbeddingProvider
    ) async -> RunResult {
        var run = RunResult(model: model, provider: provider, mode: mode, prefixFamily: prefixFamily)
        do {
            let store = try SQLiteVectorStore(embeddingProvider: embeddingProvider)

            let indexStart = Date()
            for page in Self.wiki {
                try await store.indexText(page.text, path: page.path, source: "wiki")
            }
            run.indexSeconds = Date().timeIntervalSince(indexStart)

            var ranks: [Int] = []
            var gaps: [Double] = []
            var totalQuerySeconds = 0.0
            for query in Self.queries {
                let queryStart = Date()
                let hits = try await store.hybridSearch(text: query.text, topN: Self.wiki.count)
                totalQuerySeconds += Date().timeIntervalSince(queryStart)

                let rank = (hits.firstIndex { $0.path == query.expected }).map { $0 + 1 } ?? 0
                let gap = hits.count > 1 ? hits[0].score - hits[1].score : 0
                ranks.append(rank)
                if rank == 1 { gaps.append(gap) }
                run.queries.append(QueryResult(
                    query: query.text, kind: query.kind, expected: query.expected,
                    topPath: hits.first?.path ?? "", rank: rank, gap: gap
                ))
            }

            run.queryCount = ranks.count
            run.top1 = ranks.filter { $0 == 1 }.count
            run.mrr = ranks.map { $0 > 0 ? 1.0 / Double($0) : 0 }.reduce(0, +) / Double(ranks.count)
            run.meanGapOnCorrect = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
            run.meanQuerySeconds = totalQuerySeconds / Double(Self.queries.count)
        } catch {
            run.error = "\(error)"
        }
        return run
    }

    /// Cosine between the role-aware query embedding and the bare embedding
    /// of the same probe. ~1.0 → the role-aware path changed nothing;
    /// noticeably below 1 → the prefix/task type actually engaged.
    private func probeCosine(_ provider: any EmbeddingProvider) async -> Double? {
        let probe = "a courageous wyrm"
        guard let roleAware = try? await provider.embedding(for: probe, role: .query),
              let bare = try? await provider.embedding(for: probe),
              !roleAware.isEmpty, roleAware.count == bare.count else { return nil }
        let dot = zip(roleAware, bare).map(*).reduce(0, +)
        let magnitudes = sqrt(roleAware.map { $0 * $0 }.reduce(0, +))
            * sqrt(bare.map { $0 * $0 }.reduce(0, +))
        return magnitudes > 0 ? dot / magnitudes : nil
    }
}

#endif
