//
//  SQLiteVectorStoreTypes.swift
//  SwiftAgents
//
//  Errors of ``SQLiteVectorStore``. The shared search/indexing value types
//  (`MemoryMatch`, `IndexOutcome`, `SyncSummary`) live un-gated in
//  SemanticStore.swift, where the store-agnostic protocol is declared.
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

#endif
