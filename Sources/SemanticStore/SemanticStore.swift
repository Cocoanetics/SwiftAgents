//
//  SemanticStore.swift
//  SwiftAgents
//
//  The store-agnostic semantic index API: one protocol for "index documents
//  under a (path, source) identity, search them by meaning" plus the shared
//  result types. `SQLiteVectorStore` implements it on-device (sqlite-vec +
//  FTS5); `OpenAIVectorStore` implements it against OpenAI's hosted vector
//  stores — callers written against `SemanticStore` run on either.
//
//  Engine-specific capabilities (the SQLite store's keyword / hybrid / fused
//  search, the hosted store's server-side chunking options) stay on the
//  concrete types; this protocol is the portable core.
//

import Foundation

/// A persistent semantic index of documents, addressed by a logical
/// (`path`, `source`) identity and searched by natural-language query.
///
/// `path` is provenance, not necessarily a filesystem location — index a
/// description under an image's path and the citation still points at the
/// image. Re-indexing the same (`path`, `source`) replaces the prior content.
public protocol SemanticStore: AnyObject {
    /// Indexes `text` under (`path`, `source`), replacing whatever the store
    /// held for that identity. Returns the number of stored units — chunks
    /// for stores that chunk client-side, 1 when chunking happens elsewhere.
    @discardableResult
    func indexText(_ text: String, path: String, source: String) async throws -> Int

    /// Indexes a file on disk incrementally — unchanged content (by hash) is
    /// not re-indexed. `workspaceDir`, if given, is stripped from the stored
    /// path so citations stay relative.
    @discardableResult
    func indexFile(at filePath: String, source: String, workspaceDir: String?) async throws -> IndexOutcome

    /// Indexes every file in `files` (incrementally), then prunes documents
    /// of this `source` that are no longer listed.
    @discardableResult
    func sync(files: [String], source: String, workspaceDir: String?) async throws -> SyncSummary

    /// The `topN` chunks most relevant to `text`, optionally restricted to
    /// the given `sources`. Higher score is better.
    func search(text: String, topN: Int, sources: [String]?) async throws -> [MemoryMatch]

    /// The number of indexed units — chunks for stores that chunk
    /// client-side, documents when chunking happens server-side.
    func count() async throws -> Int
}

/// One search hit, carrying the chunk text, its score, and full provenance.
public struct MemoryMatch: Equatable, Sendable {
    public let path: String
    public let source: String
    /// 1-indexed line span within the document; `0`/`0` means the match
    /// covers the whole artifact (media, or server-side chunking without
    /// line provenance).
    public let startLine: Int
    public let endLine: Int
    public let text: String
    /// Relevance — cosine for vector search, normalized bm25 for keyword
    /// search, the weighted blend for hybrid search. Higher is better.
    public let score: Double

    public init(path: String, source: String, startLine: Int, endLine: Int, text: String, score: Double) {
        self.path = path
        self.source = source
        self.startLine = startLine
        self.endLine = endLine
        self.text = text
        self.score = score
    }

    /// `source:path:startLine:endLine`, a citation the model can point at — and
    /// re-read — the exact passage by. The line span is omitted when the match
    /// covers the whole artifact.
    public var citation: String {
        startLine == 0 && endLine == 0
            ? "\(source):\(path)"
            : "\(source):\(path):\(startLine):\(endLine)"
    }
}

/// What happened when (re)indexing a file.
public enum IndexOutcome: Equatable, Sendable {
    case indexed(chunks: Int)
    case unchanged
    case missing
}

/// Tally returned by ``SemanticStore/sync(files:source:workspaceDir:)``.
public struct SyncSummary: Equatable, Sendable {
    public var indexed = 0
    public var unchanged = 0
    public var removed = 0
    public var missing = 0

    public init() {}
}
