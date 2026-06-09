//
//  Reranking.swift
//  SwiftAgents
//
//  Reranking — a precise second pass over the top fused candidates. A
//  cross-encoder (or an LLM) judges each (query, chunk) pair directly, which is
//  sharper than first-pass retrieval but too costly to run over the whole corpus,
//  so it's applied only to the fused shortlist. Its score is then blended with the
//  candidate's fusion rank — position-aware — so the reranker reorders without
//  overruling a strong retrieval signal.
//
//  Modeled on qmd's reranker + position-aware blend
//  (github.com/tobi/qmd, src/store.ts / src/llm.ts).
//

import Foundation

/// Scores how well each candidate answers the query — one score per candidate,
/// aligned by index. Higher is more relevant; the magnitude only needs to be
/// consistent within a call (it's blended, then re-sorted).
public protocol Reranker: Sendable {
    func scores(query: String, candidates: [String], intent: String?) async throws -> [Double]
}

/// A reranker driven by a per-document scoring closure, so the engine stays free
/// of any specific cross-encoder / LLM. The consumer wires `score` to a reranker
/// model or a relevance prompt. An explicit `intent` is prepended to the query
/// before scoring (qmd's behavior). A failed score counts as 0.
public struct LLMReranker: Reranker {
    public typealias Score = @Sendable (_ query: String, _ document: String) async throws -> Double

    private let score: Score

    public init(score: @escaping Score) {
        self.score = score
    }

    public func scores(query: String, candidates: [String], intent: String?) async throws -> [Double] {
        let rerankQuery: String
        if let intent, !intent.isEmpty {
            rerankQuery = "\(intent)\n\n\(query)"
        } else {
            rerankQuery = query
        }

        var results: [Double] = []
        results.reserveCapacity(candidates.count)
        for document in candidates {
            results.append((try? await self.score(rerankQuery, document)) ?? 0)
        }
        return results
    }
}
