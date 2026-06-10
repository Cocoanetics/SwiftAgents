//
//  SQLiteVectorStoreTypes.swift
//  SwiftAgents
//
//  The public value types of ``SQLiteVectorStore`` — errors, search hits,
//  and the indexing/sync result shapes. Split out of SQLiteVectorStore.swift
//  to keep the store implementation itself within the file-length budget.
//

#if SQLiteVectorStore

import Foundation

/// Errors thrown by ``SQLiteVectorStore``.
public enum SQLiteVectorStoreError: Error, CustomStringConvertible {
    case dimensionMismatch(expected: Int, got: Int)
    case embeddingConfigurationChanged(stored: String?, current: String)

    public var description: String {
        switch self {
            case let .dimensionMismatch(expected, got):
                return "embedding dimension \(got) does not match store dimension \(expected)"
            case let .embeddingConfigurationChanged(stored, current):
                return "stored embeddings use a different model or prompt format "
                    + "(fingerprint \(stored ?? "none") ≠ \(current)) — rebuild the index"
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

#endif
