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
//  Backed by SwiftPorts' `SQLiteKit`; gated behind the package's opt-in
//  `SQLiteVectorStore` trait, so the default build never pulls SwiftPorts in.
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
            guard let embedding = try await embeddingProvider.embedding(for: chunk.text) else { continue }
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

    /// Indexes a file on disk, skipping it when its content hash is unchanged
    /// since the last index (the incremental fast path). `workspaceDir`, if
    /// given, is stripped from the stored `path` so citations stay relative.
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
        let hash = Self.contentHash(content)
        let storedPath = Self.relativePath(filePath, to: workspaceDir)

        if try fileHash(path: storedPath, source: source) == hash {
            return .unchanged
        }

        let chunkCount = try await indexText(content, path: storedPath, source: source)
        let attributes = try? FileManager.default.attributesOfItem(atPath: filePath)
        let mtime = Int((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        try upsertFile(path: storedPath, source: source, hash: hash, mtime: mtime, size: content.utf8.count)
        return .indexed(chunks: chunkCount)
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

    // MARK: - Search

    /// The `topN` chunks most similar to `text` by cosine distance, optionally
    /// restricted to the given `sources`. `score` is cosine similarity.
    public func search(text: String, topN: Int, sources: [String]? = nil) async throws -> [MemoryMatch] {
        guard topN > 0, dimensions != nil,
              let query = try await embeddingProvider.embedding(for: text) else { return [] }
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
        if let query = try await embeddingProvider.embedding(for: text) {
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
