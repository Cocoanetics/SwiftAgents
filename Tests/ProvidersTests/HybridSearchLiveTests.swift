//
//  HybridSearchLiveTests.swift
//  SwiftAgents
//
//  Live end-to-end coverage for the Canon-style wiki flow: a directory of
//  markdown pages synced into a `SQLiteVectorStore` (source "wiki", paths
//  stored relative to the workspace), then queried through `hybridSearch` —
//  vec0 cosine KNN + FTS5 bm25 in a 0.7/0.3 weighted blend. The offline
//  `SQLiteVectorStoreTests` prove the fusion math on stub vectors; these
//  prove the same pipeline (chunk → role-aware embed → float32 pack → KNN +
//  bm25 → blend → hydrate with citations → incremental re-sync) holds up
//  against real embedding geometry.
//
//  Gated on the `SQLiteVectorStore` trait plus per-provider environment:
//      swift test --traits SQLiteVectorStore --filter HybridSearchLiveTests
//  with `OPENAI_API_KEY` for the OpenAI leg (text-embedding-3-small) and
//  `LMSTUDIO_URL` for the LM Studio leg (text-embedding-nomic-embed-text-v1.5
//  unless overridden via `LMSTUDIO_EMBED_MODEL`; skipped when not downloaded).
//

#if SQLiteVectorStore

import Foundation
@testable import Providers
import Testing
@testable import SemanticStore

struct HybridSearchLiveTests {
    /// A miniature Canon wiki: four markdown pages with clearly separated
    /// topics, written so each retrieval leg has a page only it can lift:
    ///
    ///   - `Characters/Stormy.md` and `Places/Saltmere.md` are the semantic
    ///     targets — their test queries share no content word with the page,
    ///     so bm25 has nothing to grab and the vector leg must carry them.
    ///   - `Lore/Shardfall.md` is the keyword target — "Vexglass" is an
    ///     invented proper noun that FTS5 matches exactly.
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
            path: "Places/Saltmere.md",
            text: """
            # Saltmere

            Saltmere is a harbor town built on stilts over the tide flats. Boats unload
            herring and kelp at the morning market, and the smell of salt and tar hangs
            over the boardwalks all year.
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
        )
    ]

    @Test(
        "OpenAI embeddings drive Canon-style hybrid wiki search",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func openAIHybridWikiSearch() async throws {
        try await assertHybridWikiSearch(embeddingProvider: TestClients.openAI())
    }

    @Test(
        "LM Studio embeddings drive Canon-style hybrid wiki search",
        .enabled(if: TestClients.hasLMStudio, "Requires LMSTUDIO_URL")
    )
    func lmStudioHybridWikiSearch() async throws {
        let client = try TestClients.lmStudio()
        // LM Studio orders /v1/models by recent use, so "first id containing
        // embed" is a moving target across runs — it can even land on a
        // reranker. Pin a known-good embedding model (instruction-tuned ones
        // get their task prefixes via `EmbeddingTaskPrefix` on the role-aware
        // path) and skip when it isn't downloaded; override via
        // LMSTUDIO_EMBED_MODEL.
        let model = ProcessInfo.processInfo.environment["LMSTUDIO_EMBED_MODEL"]
            ?? "text-embedding-nomic-embed-text-v1.5"
        guard let models = try? await client.models(), models.contains(where: { $0.id == model }) else {
            return
        }
        client.embeddingModelIdentifier = model
        try await assertHybridWikiSearch(embeddingProvider: client)
    }

    @Test(
        "Gemini embeddings drive Canon-style hybrid wiki search",
        .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY")
    )
    func geminiHybridWikiSearch() async throws {
        // Defaults to gemini-embedding-2, whose retrieval prompts arrive via
        // the shared EmbeddingTaskPrefix table (the EmbeddingGemma format).
        try await assertHybridWikiSearch(embeddingProvider: try TestClients.google())
    }

    @Test(
        "Gemini embedding-001 task types drive Canon-style hybrid wiki search",
        .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY")
    )
    func geminiLegacyTaskTypeHybridWikiSearch() async throws {
        // The pre-instruction model: roles travel as the taskType API
        // parameter (RETRIEVAL_QUERY / RETRIEVAL_DOCUMENT), not as prompts.
        let client = try TestClients.google()
        client.embeddingModelIdentifier = "gemini-embedding-001"
        try await assertHybridWikiSearch(embeddingProvider: client)
    }

    // MARK: - Shared flow

    /// Mirrors Canon's `WikiSearchIndex`: write the wiki to disk, `sync` it
    /// (source "wiki", workspace-relative paths), then run `hybridSearch`
    /// with the default 0.7 vector / 0.3 keyword blend and verify ranking,
    /// provenance, and the incremental re-sync fast path.
    private func assertHybridWikiSearch(embeddingProvider: any EmbeddingProvider) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hybrid-wiki-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var files: [String] = []
        for page in Self.wiki {
            let url = root.appendingPathComponent(page.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try page.text.write(to: url, atomically: true, encoding: .utf8)
            files.append(url.path)
        }

        let store = try SQLiteVectorStore(embeddingProvider: embeddingProvider)
        let summary = try await store.sync(files: files, source: "wiki", workspaceDir: root.path)
        #expect(summary.indexed == Self.wiki.count)
        #expect(try store.count() == Self.wiki.count)

        // Vector leg: the query shares no content word with the dragon page
        // (Canon's own "courageous wyrm" probe) — only embeddings can lift it.
        let wyrm = try await store.hybridSearch(text: "a courageous wyrm", topN: 3)
        #expect(wyrm.first?.path == "Characters/Stormy.md")

        // Provenance survives the trip: workspace-relative path, wiki source,
        // and a 1-indexed line span — the citation Canon renders to the model.
        let top = try #require(wyrm.first)
        #expect(top.source == "wiki")
        #expect(top.startLine == 1)
        #expect(top.citation.hasPrefix("wiki:Characters/Stormy.md:1:"))
        #expect(top.text.contains("dragon"))

        // Second semantic probe, paraphrased against a different page.
        let market = try await store.hybridSearch(text: "where do fishermen sell their catch", topN: 3)
        #expect(market.first?.path == "Places/Saltmere.md")

        // Keyword leg: an invented proper noun — exact-match bm25 territory.
        let vexglass = try await store.hybridSearch(text: "Vexglass", topN: 3)
        #expect(vexglass.first?.path == "Lore/Shardfall.md")

        // Incremental fast path: a second sync re-embeds nothing.
        let resync = try await store.sync(files: files, source: "wiki", workspaceDir: root.path)
        #expect(resync.unchanged == Self.wiki.count)
        #expect(resync.indexed == 0)
    }
}

#endif
