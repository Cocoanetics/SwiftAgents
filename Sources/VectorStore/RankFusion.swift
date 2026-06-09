//
//  RankFusion.swift
//  SwiftAgents
//
//  Reciprocal Rank Fusion (RRF) — merge several independently-ranked result
//  lists into one. Because it fuses on *rank* rather than raw score, it sidesteps
//  the usual problem of making incomparable scores (cosine vs. bm25 vs. a reranker)
//  share a scale. Used to combine the legs of a hybrid / multi-query search.
//
//  Derived from qmd's `reciprocalRankFusion` (github.com/tobi/qmd, src/store.ts).
//

import Foundation

/// Fuses rank-ordered lists into one ranking.
///
/// Each list is `(items, weight)` where `items` is best-first. An item's fused
/// score is `Σ weight / (k + rank + 1)` over every list it appears in (rank is
/// 0-indexed), plus a small `topRankBonuses` lift for topping any single list.
/// Higher `k` flattens the rank curve (later ranks matter more); the default 60
/// is the canonical RRF constant.
///
/// Pass a higher `weight` for the "original" query's lists and a lower one for
/// expansion-derived lists to keep the user's literal query authoritative.
public func reciprocalRankFusion<ID: Hashable & Comparable>(
    _ rankedLists: [(items: [ID], weight: Double)],
    k: Int = 60,
    topRankBonuses: [Double] = [0.05, 0.02, 0.02]
) -> [(item: ID, score: Double)] {
    var fused: [ID: (score: Double, bestRank: Int)] = [:]
    for list in rankedLists {
        for (rank, item) in list.items.enumerated() {
            var entry = fused[item] ?? (score: 0, bestRank: .max)
            entry.score += list.weight / Double(k + rank + 1)
            entry.bestRank = min(entry.bestRank, rank)
            fused[item] = entry
        }
    }
    return fused
        .map { item, value -> (item: ID, score: Double) in
            let bonus = value.bestRank < topRankBonuses.count ? topRankBonuses[value.bestRank] : 0
            return (item, value.score + bonus)
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.item < $1.item }
}
