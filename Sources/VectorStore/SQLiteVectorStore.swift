//
//  SQLiteVectorStore.swift
//  SwiftAgents
//
//  A persistent, SQLite-backed cousin of `LocalVectorStore`. Embeddings live
//  in a sqlite-vec `vec0` index (cosine KNN runs inside the engine) and the
//  chunk text is mirrored into an FTS5 index, so one store answers semantic
//  (`search`), keyword (`keywordSearch`), and fused (`hybridSearch`) queries.
//
//  Provenance + incremental indexing mirror openclaw's memory engine: every
//  chunk records its source `path`, a `source` category, and its line span
//  (`startLine`/`endLine`); a `files` table tracks per-file hashes so re-
//  indexing skips unchanged files and prunes deleted ones; and results render
//  a `source:path:start:end` citation.
//
//  Backed by `SQLiteKit` (Cocoanetics/SQLiteKit); gated behind the package's
//  opt-in `SQLiteVectorStore` trait, so the default build never compiles it.
//

#if SQLiteVectorStore

import Foundation
import Providers
import SQLiteKit

/// Errors thrown by ``SQLiteVectorStore``.
public enum SQLiteVectorStoreError: Error, CustomStringConvertible {
    case dimensionMismatch(expected: Int, got: Int)

    public var description: String {
        switch self {
            case let .dimensionMismatch(expected, got):
                return "embedding dimension \(got) does not match store dimension \(expected)"
        }
    }
}

/// One search hit, carrying the chunk text, its score, and full provenance.
public struct MemoryMatch: Equatable {
    public let path: String
    public let source: String
    public let startLine: Int
    public let endLine: Int
    public let text: String
    /// Relevance — cosine for vector search, normalized bm25 for keyword
    /// search, the weighted blend for hybrid search. Higher is better.
    public let score: Double

    /// `source:path:startLine:endLine`, a citation the model can point at — and
    /// re-read — the exact passage by.
    public var citation: String { "\(source):\(path):\(startLine):\(endLine)" }
}

/// What happened when (re)indexing a file.
public enum IndexOutcome: Equatable {
    case indexed(chunks: Int)
    case unchanged
    case missing
}

/// Tally returned by ``SQLiteVectorStore/sync(files:source:workspaceDir:)``.
public struct SyncSummary: Equatable {
    public var indexed = 0
    public var unchanged = 0
    public var removed = 0
    public var missing = 0
}

/// One in-memory document for ``SQLiteVectorStore/sync(documents:source:)`` —
/// text that doesn't live in a file of its own (e.g. a description stored in
/// metadata), indexed under the `path` it should be cited as.
public struct SyncDocument: Equatable, Sendable {
    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

/// Stores text chunks and their embeddings in SQLite, searchable by semantic
/// similarity (sqlite-vec `vec0`, cosine), full-text keyword match (FTS5), or a
/// fusion of both — with file-level provenance and incremental re-indexing.
public final class SQLiteVectorStore {
    /// Where the database lives. `.memory` is ephemeral; `.file` persists.
    public enum Storage {
        case memory
        case file(String)
    }

    /// Candidate over-sampling factor for searches that post-filter by source
    /// (so the cut to `topN` still has enough survivors), matching openclaw's 8×.
    private static let filterOversample = 8

    private let database: SQLiteDatabase
    private let embeddingProvider: EmbeddingProvider
    /// Fixed once the first vector is indexed (or recovered on reopen).
    private var dimensions: Int?

    /// Opens (or creates) a store. `.memory` is ephemeral; `.file(path)`
    /// persists and recovers prior vectors on reopen. On Apple platforms the
    /// embedding provider defaults to on-device `NLContextualEmbedding` (no API
    /// key, no extra model); elsewhere supply one explicitly (e.g. `OpenAI`).
    public init(storage: Storage = .memory, embeddingProvider: EmbeddingProvider? = nil) throws {
        #if canImport(NaturalLanguage)
        self.embeddingProvider = embeddingProvider ?? ContextualEmbeddingProvider()
        #else
        guard let embeddingProvider else {
            preconditionFailure(
                "SQLiteVectorStore requires an explicit embeddingProvider on platforms without NaturalLanguage."
            )
        }
        self.embeddingProvider = embeddingProvider
        #endif

        let location: SQLiteDatabase.Location
        switch storage {
            case .memory: location = .memory
            case let .file(path): location = .file(path)
        }
        self.database = try SQLiteDatabase(location)
        try ensureBaseSchema()
        self.dimensions = try Self.readConfiguredDimensions(database)
    }

    /// Number of indexed chunks.
    public func count() throws -> Int {
        guard let row = try database.evaluate("SELECT count(*) FROM chunks;").first?.rows.first,
              case let .integer(value) = row[0] else { return 0 }
        return Int(value)
    }

    // MARK: - Indexing

    /// Chunks `text` (line-aware, with overlap), embeds each chunk, and stores
    /// it under (`path`, `source`). Re-indexing the same (`path`, `source`)
    /// replaces its previous chunks. Returns the number of chunks stored.
    @discardableResult
    public func indexText(_ text: String, path: String, source: String = "memory") async throws -> Int {
        // Embed first (the only async work), then write synchronously — keeps
        // the non-Sendable SQLite handles off the await path.
        var pending: [(chunk: LineChunk, embedding: Vector)] = []
        for chunk in LineChunker.chunk(text) {
            guard let embedding = try await embeddingProvider.embedding(for: chunk.text, role: .document)
            else { continue }
            pending.append((chunk, embedding))
        }
        guard let first = pending.first else {
            try deleteChunks(path: path, source: source)   // nothing to store → clear prior
            return 0
        }
        try ensureVectorSchema(dimensions: first.embedding.count)
        guard let dimensions else { return 0 }

        let model = embeddingProvider.embeddingModelIdentifier
        let now = Int(Date().timeIntervalSince1970)
        try database.execute("BEGIN;")
        do {
            try deleteChunks(path: path, source: source)
            let insertChunk = try SQLiteStatement(database, """
                INSERT INTO chunks(path, source, start_line, end_line, hash, model, text, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """)
            let insertVector = try SQLiteStatement(
                database, "INSERT INTO vec_chunks(chunk_id, embedding) VALUES (?, ?);"
            )
            let insertText = try SQLiteStatement(
                database, "INSERT INTO fts_chunks(rowid, text) VALUES (?, ?);"
            )
            for entry in pending {
                guard entry.embedding.count == dimensions else {
                    throw SQLiteVectorStoreError.dimensionMismatch(expected: dimensions, got: entry.embedding.count)
                }
                try insertChunk.bind([
                    .text(path), .text(source),
                    .integer(Int64(entry.chunk.startLine)), .integer(Int64(entry.chunk.endLine)),
                    .text(Self.contentHash(entry.chunk.text)), .text(model),
                    .text(entry.chunk.text), .integer(Int64(now))
                ])
                _ = try insertChunk.step()
                insertChunk.reset()

                let id = database.lastInsertRowID
                try insertVector.bind([.integer(id), .blob(Self.packedFloat32(entry.embedding))])
                _ = try insertVector.step()
                insertVector.reset()

                try insertText.bind([.integer(id), .text(entry.chunk.text)])
                _ = try insertText.step()
                insertText.reset()
            }
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
        return pending.count
    }

    /// Indexes one document, skipping it when its text hash is unchanged since
    /// the last index (the incremental fast path). The core primitive behind
    /// both sync flavors — a file is just one way to obtain a document.
    @discardableResult
    public func indexDocument(_ document: SyncDocument, source: String = "memory") async throws -> IndexOutcome {
        let hash = Self.contentHash(document.text)
        if try fileHash(path: document.path, source: source) == hash {
            return .unchanged
        }
        let chunkCount = try await indexText(document.text, path: document.path, source: source)
        try upsertFile(
            path: document.path,
            source: source,
            hash: hash,
            mtime: Int(Date().timeIntervalSince1970),
            size: document.text.utf8.count
        )
        return .indexed(chunks: chunkCount)
    }

    /// Indexes a file on disk — reads it and delegates to ``indexDocument(_:source:)``,
    /// so the incremental hash-skip is shared. `workspaceDir`, if given, is
    /// stripped from the stored `path` so citations stay relative.
    @discardableResult
    public func indexFile(
        at filePath: String,
        source: String = "memory",
        workspaceDir: String? = nil
    ) async throws -> IndexOutcome {
        let content: String
        do {
            content = try String(contentsOfFile: filePath, encoding: .utf8)
        } catch {
            return .missing
        }
        return try await indexDocument(
            SyncDocument(path: Self.relativePath(filePath, to: workspaceDir), text: content),
            source: source
        )
    }

    /// Indexes every file in `files` (incrementally), then prunes chunks for
    /// any previously-indexed file of this `source` that is no longer listed —
    /// the directory-sync flow openclaw runs over its memory folder.
    @discardableResult
    public func sync(
        files: [String],
        source: String = "memory",
        workspaceDir: String? = nil
    ) async throws -> SyncSummary {
        var summary = SyncSummary()
        var seen = Set<String>()
        for file in files {
            switch try await indexFile(at: file, source: source, workspaceDir: workspaceDir) {
                case .indexed:
                    summary.indexed += 1
                    seen.insert(Self.relativePath(file, to: workspaceDir))
                case .unchanged:
                    summary.unchanged += 1
                    seen.insert(Self.relativePath(file, to: workspaceDir))
                case .missing:
                    summary.missing += 1
            }
        }
        summary.removed = try prune(source: source, keep: seen)
        return summary
    }

    /// Indexes every in-memory document (incrementally — a document whose text
    /// hash is unchanged is not re-embedded), then prunes chunks for any
    /// previously-indexed path of this `source` that is no longer listed. The
    /// document twin of ``sync(files:source:workspaceDir:)``, for content that
    /// doesn't live in a file of its own — e.g. descriptions kept in metadata.
    @discardableResult
    public func sync(documents: [SyncDocument], source: String = "memory") async throws -> SyncSummary {
        var summary = SyncSummary()
        var seen = Set<String>()
        for document in documents {
            seen.insert(document.path)
            switch try await indexDocument(document, source: source) {
                case .indexed: summary.indexed += 1
                case .unchanged: summary.unchanged += 1
                case .missing: summary.missing += 1
            }
        }
        summary.removed = try prune(source: source, keep: seen)
        return summary
    }

    // MARK: - Search

    /// The `topN` chunks most similar to `text` by cosine distance, optionally
    /// restricted to the given `sources`. `score` is cosine similarity.
    public func search(text: String, topN: Int, sources: [String]? = nil) async throws -> [MemoryMatch] {
        guard topN > 0, dimensions != nil,
              let query = try await embeddingProvider.embedding(for: text, role: .query) else { return [] }
        let candidates = try vectorCandidates(query, limit: candidateLimit(topN, sources))
        return Array(try hydrate(candidates, sources: sources).prefix(topN))
    }

    /// The `topN` chunks matching the FTS5 `query` (caller supplies valid FTS5
    /// syntax), ranked by bm25 normalized to `(0, 1]`, optionally restricted to
    /// `sources`.
    public func keywordSearch(_ query: String, topN: Int, sources: [String]? = nil) throws -> [MemoryMatch] {
        guard topN > 0, dimensions != nil else { return [] }
        let candidates = try keywordCandidates(matching: query, limit: candidateLimit(topN, sources))
        return Array(try hydrate(candidates, sources: sources).prefix(topN))
    }

    /// Hybrid search: fuse semantic (vec0 cosine) and lexical (FTS5 bm25)
    /// retrieval. Both legs are normalized to `[0, 1]` and combined as
    /// `vectorWeight * cosine + textWeight * bm25`, unioned by chunk — a chunk
    /// found by only one leg scores 0 on the other. Each leg over-samples
    /// `topN * oversample` candidates. Degrades to lexical-only when no
    /// embedding is available, and to semantic-only when the query has no terms.
    public func hybridSearch(
        text: String,
        topN: Int,
        vectorWeight: Double = 0.7,
        textWeight: Double = 0.3,
        oversample: Int = 8,
        sources: [String]? = nil
    ) async throws -> [MemoryMatch] {
        guard topN > 0, dimensions != nil else { return [] }
        let limit = topN * max(1, oversample)

        var keyword: [(id: Int64, score: Double)] = []
        if let ftsQuery = Self.buildFTSQuery(text) {
            keyword = (try? keywordCandidates(matching: ftsQuery, limit: limit)) ?? []
        }
        var vector: [(id: Int64, score: Double)] = []
        if let query = try await embeddingProvider.embedding(for: text, role: .query) {
            vector = try vectorCandidates(query, limit: limit)
        }

        var fused: [Int64: (vector: Double, text: Double)] = [:]
        for entry in vector { fused[entry.id, default: (vector: 0, text: 0)].vector = entry.score }
        for entry in keyword { fused[entry.id, default: (vector: 0, text: 0)].text = entry.score }

        let ranked = fused
            .map { (id: $0.key, score: vectorWeight * $0.value.vector + textWeight * $0.value.text) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
        // No filter → cut early; filtering needs the full list before the cut.
        let candidates = sources == nil ? Array(ranked.prefix(topN)) : ranked
        return Array(try hydrate(candidates, sources: sources).prefix(topN))
    }

    /// Multi-query search fused with Reciprocal Rank Fusion. Every `vector` query
    /// is embedded and run as vec0 cosine KNN; every `keyword` query is run as
    /// FTS5 bm25; all the resulting ranked lists are merged by
    /// `reciprocalRankFusion`. The first `vector` and first `keyword` query are
    /// treated as the user's "original" and weighted `originalWeight`; any further
    /// queries (e.g. lex/vec/hyde expansions) get `expansionWeight`.
    ///
    /// This is the seam query expansion plugs into: pass the raw query alone
    /// (`vector: [q], keyword: [q]`) for a plain RRF hybrid, or the raw query plus
    /// expansions for the full pipeline. Each leg over-samples `topN * oversample`
    /// candidates. Returns up to `topN` chunks scored by their fused RRF rank.
    public func fusedSearch(
        vector vectorQueries: [String],
        keyword keywordQueries: [String],
        topN: Int,
        originalWeight: Double = 2.0,
        expansionWeight: Double = 1.0,
        k: Int = 60,
        oversample: Int = 8,
        sources: [String]? = nil
    ) async throws -> [MemoryMatch] {
        guard topN > 0, dimensions != nil else { return [] }
        let limit = candidateLimit(topN * max(1, oversample), sources)

        var lists: [(items: [Int64], weight: Double)] = []
        for (index, text) in vectorQueries.enumerated() {
            guard let query = try await embeddingProvider.embedding(for: text, role: .query) else { continue }
            let ids = try vectorCandidates(query, limit: limit).map(\.id)
            lists.append((ids, index == 0 ? originalWeight : expansionWeight))
        }
        for (index, text) in keywordQueries.enumerated() {
            guard let ftsQuery = Self.buildFTSQuery(text) else { continue }
            let ids = ((try? keywordCandidates(matching: ftsQuery, limit: limit)) ?? []).map(\.id)
            lists.append((ids, index == 0 ? originalWeight : expansionWeight))
        }
        guard !lists.isEmpty else { return [] }

        let fused = reciprocalRankFusion(lists, k: k).map { (id: $0.item, score: $0.score) }
        let candidates = sources == nil ? Array(fused.prefix(topN)) : fused
        return Array(try hydrate(candidates, sources: sources).prefix(topN))
    }

    /// Expansion-driven search: rewrites `text` into typed sub-queries via
    /// `expander` (`.lex` → keyword, `.vec` / `.hyde` → vector), then fuses the
    /// original query together with every expansion through `fusedSearch` / RRF
    /// (the original is weighted above its expansions). A strong-signal gate skips
    /// the expansion entirely when a bm25 probe shows the literal query already has
    /// a clear winner. Degrades to the plain query if the expander throws. For
    /// custom fusion weights, route expansions through `fusedSearch` directly.
    public func expandedSearch(
        text: String,
        using expander: QueryExpander,
        intent: String? = nil,
        topN: Int,
        strongSignalGating: Bool = true,
        strongSignalMinScore: Double = 0.85,
        strongSignalMinGap: Double = 0.15,
        sources: [String]? = nil
    ) async throws -> [MemoryMatch] {
        // Strong-signal gate: a quick bm25 probe. When the top keyword hit is
        // clearly ahead of the runner-up the literal query already nails it, so
        // skip the (possibly expensive) expansion. An explicit `intent` always
        // expands — it may disambiguate a non-obvious match.
        if strongSignalGating, intent == nil, let ftsQuery = Self.buildFTSQuery(text) {
            let probe = (try? keywordCandidates(matching: ftsQuery, limit: 2)) ?? []
            let top = probe.first?.score ?? 0
            let second = probe.count > 1 ? probe[1].score : 0
            if top >= strongSignalMinScore, top - second >= strongSignalMinGap {
                return try await fusedSearch(vector: [text], keyword: [text], topN: topN, sources: sources)
            }
        }

        let expansions = (try? await expander.expand(text, intent: intent)) ?? []
        var vectorQueries = [text]    // index 0 is the user's original → highest RRF weight
        var keywordQueries = [text]
        for expansion in expansions {
            switch expansion.kind {
                case .lex: keywordQueries.append(expansion.text)
                case .vec, .hyde: vectorQueries.append(expansion.text)
            }
        }
        return try await fusedSearch(vector: vectorQueries, keyword: keywordQueries, topN: topN, sources: sources)
    }

    /// Reranks `candidates` (given in fused / RRF order) with `reranker`, blending
    /// each candidate's reranker score with its fusion rank — position-aware, so
    /// the reranker reorders the shortlist without overruling a strong retrieval
    /// signal. Blend: `rrfWeight · (1 / rank) + (1 − rrfWeight) · rerankScore`,
    /// where `rrfWeight` is 0.75 (rank 1–3) / 0.60 (4–10) / 0.40 (11+). Returns
    /// the candidates re-sorted, each carrying its blended score. Typically run
    /// over a `fusedSearch` / `expandedSearch` shortlist, then sliced to the final
    /// result count.
    public func rerank(
        query: String,
        candidates: [MemoryMatch],
        using reranker: Reranker,
        intent: String? = nil
    ) async throws -> [MemoryMatch] {
        guard !candidates.isEmpty else { return [] }
        let scores = try await reranker.scores(
            query: query, candidates: candidates.map(\.text), intent: intent)

        let blended = candidates.enumerated().map { index, candidate -> MemoryMatch in
            let rrfRank = index + 1                                   // 1-indexed fusion position
            let rrfWeight = rrfRank <= 3 ? 0.75 : (rrfRank <= 10 ? 0.60 : 0.40)
            let rerankScore = index < scores.count ? scores[index] : 0
            let blendedScore = rrfWeight * (1.0 / Double(rrfRank)) + (1 - rrfWeight) * rerankScore
            return MemoryMatch(
                path: candidate.path, source: candidate.source,
                startLine: candidate.startLine, endLine: candidate.endLine,
                text: candidate.text, score: blendedScore)
        }
        return blended.sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
    }

    // MARK: - Retrieval legs

    private func candidateLimit(_ topN: Int, _ sources: [String]?) -> Int {
        sources == nil ? topN : topN * Self.filterOversample
    }

    /// `vec0` cosine KNN over the query vector; score is cosine similarity.
    private func vectorCandidates(_ query: Vector, limit: Int) throws -> [(id: Int64, score: Double)] {
        let knn = try database.evaluate(
            """
            SELECT chunk_id, distance FROM vec_chunks
            WHERE embedding MATCH ? AND k = \(limit)
            ORDER BY distance;
            """,
            [.blob(Self.packedFloat32(query))]
        )
        return (knn.first?.rows ?? []).compactMap { row -> (id: Int64, score: Double)? in
            guard case let .integer(id) = row[0] else { return nil }
            return (id, 1 - Self.double(row[1]))
        }
    }

    /// FTS5 `MATCH` over `query`; score is bm25 relevance normalized to `(0, 1]`.
    private func keywordCandidates(matching query: String, limit: Int) throws -> [(id: Int64, score: Double)] {
        let hits = try database.evaluate(
            """
            SELECT rowid, rank FROM fts_chunks
            WHERE fts_chunks MATCH ?
            ORDER BY rank
            LIMIT \(limit);
            """,
            [.text(query)]
        )
        return (hits.first?.rows ?? []).compactMap { row -> (id: Int64, score: Double)? in
            guard case let .integer(id) = row[0] else { return nil }
            return (id, Self.bm25Score(Self.double(row[1])))
        }
    }

    // MARK: - Hydration

    /// Fetches provenance + text for the matched chunk ids, optionally dropping
    /// chunks outside `sources`, and re-assembles them in the engine's order.
    private func hydrate(_ ordered: [(id: Int64, score: Double)], sources: [String]?) throws -> [MemoryMatch] {
        guard !ordered.isEmpty else { return [] }
        let idList = ordered.map { String($0.id) }.joined(separator: ",")
        let rows = try database.evaluate(
            "SELECT chunk_id, path, source, start_line, end_line, text FROM chunks WHERE chunk_id IN (\(idList));"
        ).first?.rows ?? []

        let allowed = sources.map(Set.init)
        var meta: [Int64: MemoryMatch] = [:]
        for row in rows {
            guard case let .integer(id) = row[0] else { continue }
            let source = Self.string(row[2])
            if let allowed, !allowed.contains(source) { continue }
            meta[id] = MemoryMatch(
                path: Self.string(row[1]), source: source,
                startLine: Self.integer(row[3]), endLine: Self.integer(row[4]),
                text: Self.string(row[5]), score: 0
            )
        }
        return ordered.compactMap { entry in
            guard let base = meta[entry.id] else { return nil }
            return MemoryMatch(
                path: base.path, source: base.source,
                startLine: base.startLine, endLine: base.endLine,
                text: base.text, score: entry.score
            )
        }
    }

    // MARK: - File bookkeeping

    private func fileHash(path: String, source: String) throws -> String? {
        let rows = try database.evaluate(
            "SELECT hash FROM files WHERE path = ? AND source = ?;",
            [.text(path), .text(source)]
        ).first?.rows ?? []
        guard let row = rows.first, case let .text(hash) = row[0] else { return nil }
        return hash
    }

    private func upsertFile(path: String, source: String, hash: String, mtime: Int, size: Int) throws {
        try database.execute(
            """
            INSERT INTO files(path, source, hash, mtime, size) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(path, source) DO UPDATE SET
                hash = excluded.hash, mtime = excluded.mtime, size = excluded.size;
            """,
            [.text(path), .text(source), .text(hash), .integer(Int64(mtime)), .integer(Int64(size))]
        )
    }

    /// Removes a chunk and its vector + FTS rows for one (`path`, `source`).
    private func deleteChunks(path: String, source: String) throws {
        let rows = try database.evaluate(
            "SELECT chunk_id FROM chunks WHERE path = ? AND source = ?;",
            [.text(path), .text(source)]
        ).first?.rows ?? []
        let ids = rows.compactMap { row -> Int64? in
            if case let .integer(id) = row[0] { return id }
            return nil
        }
        guard !ids.isEmpty else { return }
        let idList = ids.map(String.init).joined(separator: ",")
        try database.execute("DELETE FROM vec_chunks WHERE chunk_id IN (\(idList));")
        try database.execute("DELETE FROM fts_chunks WHERE rowid IN (\(idList));")
        try database.execute("DELETE FROM chunks WHERE path = ? AND source = ?;", [.text(path), .text(source)])
    }

    /// Drops every file of `source` whose path isn't in `keep`, returning the count.
    private func prune(source: String, keep: Set<String>) throws -> Int {
        let rows = try database.evaluate(
            "SELECT path FROM files WHERE source = ?;", [.text(source)]
        ).first?.rows ?? []
        let paths = rows.compactMap { row -> String? in
            if case let .text(path) = row[0] { return path }
            return nil
        }
        var removed = 0
        for path in paths where !keep.contains(path) {
            try deleteChunks(path: path, source: source)
            try database.execute("DELETE FROM files WHERE path = ? AND source = ?;", [.text(path), .text(source)])
            removed += 1
        }
        return removed
    }

    // MARK: - Schema

    /// Dimension-independent tables — created eagerly so file bookkeeping works
    /// before any vector exists. (`vec_chunks` is created lazily; see below.)
    private func ensureBaseSchema() throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS files(
                path TEXT NOT NULL,
                source TEXT NOT NULL DEFAULT 'memory',
                hash TEXT NOT NULL,
                mtime INTEGER NOT NULL,
                size INTEGER NOT NULL,
                PRIMARY KEY (path, source)
            );
            CREATE TABLE IF NOT EXISTS chunks(
                chunk_id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT NOT NULL,
                source TEXT NOT NULL DEFAULT 'memory',
                start_line INTEGER NOT NULL,
                end_line INTEGER NOT NULL,
                hash TEXT NOT NULL,
                model TEXT NOT NULL,
                text TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_chunks_path ON chunks(path);
            CREATE INDEX IF NOT EXISTS idx_chunks_source ON chunks(source);
            CREATE TABLE IF NOT EXISTS vec_config(dimensions INTEGER NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_chunks USING fts5(text);
            """
        )
    }

    /// Creates the `vec0` index once the first embedding reveals the dimension
    /// (which `vec0` bakes into the column type), and pins it for reopen.
    private func ensureVectorSchema(dimensions dim: Int) throws {
        if let existing = dimensions {
            guard existing == dim else {
                throw SQLiteVectorStoreError.dimensionMismatch(expected: existing, got: dim)
            }
            return
        }
        try database.execute(
            """
            INSERT INTO vec_config(dimensions) VALUES(\(dim));
            CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
                chunk_id INTEGER PRIMARY KEY,
                embedding float[\(dim)] distance_metric=cosine
            );
            """
        )
        dimensions = dim
    }

    private static func readConfiguredDimensions(_ database: SQLiteDatabase) throws -> Int? {
        guard let row = try database.evaluate("SELECT dimensions FROM vec_config LIMIT 1;").first?.rows.first,
              case let .integer(dim) = row[0] else { return nil }
        return Int(dim)
    }

    // MARK: - Encoding helpers

    /// A `[Double]` embedding packed as little-endian float32 bytes — the
    /// compact blob form sqlite-vec accepts for `vec0` inserts and `MATCH`
    /// operands (≈6 KB for a 1536-d vector vs ≈20 KB as a JSON literal).
    private static func packedFloat32(_ vector: Vector) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            var littleEndian = Float(value).bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Converts FTS5's bm25 `rank` (negative; more negative = more relevant)
    /// to a `(0, 1]` relevance score, so the lexical leg can be fused with
    /// cosine on a common scale. Mirrors openclaw's `bm25RankToScore`.
    private static func bm25Score(_ rank: Double) -> Double {
        guard rank.isFinite else { return 1 / (1 + 999) }
        if rank < 0 {
            let relevance = -rank
            return relevance / (1 + relevance)
        }
        return 1 / (1 + rank)
    }

    /// Tokenizes a natural-language query into a safe FTS5 OR-query
    /// (`"foo" OR "bar"`). Returns `nil` when no usable terms remain.
    private static func buildFTSQuery(_ raw: String) -> String? {
        let tokens = raw
            .split { !($0.isLetter || $0.isNumber || $0 == "_") }
            .map(String.init)
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    /// Stable, non-cryptographic content hash (FNV-1a 64-bit) for change
    /// detection — deterministic across processes, unlike Swift's `Hasher`.
    private static func contentHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static func relativePath(_ filePath: String, to workspaceDir: String?) -> String {
        guard var base = workspaceDir else { return filePath }
        if !base.hasSuffix("/") { base += "/" }
        return filePath.hasPrefix(base) ? String(filePath.dropFirst(base.count)) : filePath
    }

    private static func double(_ value: SQLiteValue) -> Double {
        switch value {
            case let .real(number): return number
            case let .integer(number): return Double(number)
            default: return .nan
        }
    }

    private static func integer(_ value: SQLiteValue) -> Int {
        if case let .integer(number) = value { return Int(number) }
        return 0
    }

    private static func string(_ value: SQLiteValue) -> String {
        if case let .text(text) = value { return text }
        return ""
    }
}

#endif
