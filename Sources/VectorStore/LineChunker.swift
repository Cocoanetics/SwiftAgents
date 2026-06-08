//
//  LineChunker.swift
//  SwiftAgents
//
//  A line-aware, character-budgeted sliding-window chunker — a port of
//  openclaw's `chunkMarkdown` (packages/memory-host-sdk/src/host/internal.ts).
//  Accumulates lines until `maxChars`, emits a chunk tagged with its first and
//  last source line, then carries ~`overlapChars` of trailing lines into the
//  next chunk so context isn't lost at boundaries. An over-long single line is
//  split into budget-sized segments that keep their line number.
//
//  Unlike `TextChunker` (NaturalLanguage, Apple-only), this is pure Swift, so
//  it pairs with the cross-platform SQLite store — and, crucially, it reports
//  the line span each chunk came from, which the store persists as provenance.
//

#if SQLiteVectorStore

import Foundation

/// One chunk of a document with its 1-indexed line span in the source text.
struct LineChunk: Equatable {
    let text: String
    let startLine: Int
    let endLine: Int
}

enum LineChunker {
    /// Splits `content` into overlapping, line-numbered chunks. Defaults
    /// (~2000 chars, ~200 overlap) suit prose/markdown; tune for other corpora.
    static func chunk(_ content: String, maxChars: Int = 2000, overlapChars: Int = 200) -> [LineChunk] {
        let budget = max(32, maxChars)
        let overlap = max(0, overlapChars)
        // Keep blank lines so line numbers stay aligned with the source.
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return [] }

        var chunks: [LineChunk] = []
        var current: [(text: String, line: Int)] = []
        var currentChars = 0

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            chunks.append(LineChunk(
                text: current.map(\.text).joined(separator: "\n"),
                startLine: first.line,
                endLine: last.line
            ))
        }

        // After a flush, keep the trailing lines totalling ~`overlap` chars so
        // the next chunk overlaps the previous one.
        func carryOverlap() {
            guard overlap > 0, !current.isEmpty else {
                current = []
                currentChars = 0
                return
            }
            var accumulated = 0
            var kept: [(text: String, line: Int)] = []
            for entry in current.reversed() {
                accumulated += entry.text.count + 1
                kept.insert(entry, at: 0)
                if accumulated >= overlap { break }
            }
            current = kept
            currentChars = accumulated
        }

        for (index, line) in lines.enumerated() {
            let lineNo = index + 1
            let segments = line.isEmpty ? [""] : Self.segment(line, maxChars: budget)
            for segment in segments {
                let size = segment.count + 1
                if currentChars + size > budget, !current.isEmpty {
                    flush()
                    carryOverlap()
                }
                current.append((segment, lineNo))
                currentChars += size
            }
        }
        flush()
        return chunks
    }

    /// Splits a single over-long line into `≤ maxChars` pieces, breaking on
    /// `Character` boundaries so grapheme clusters stay intact.
    private static func segment(_ line: String, maxChars: Int) -> [String] {
        guard line.count > maxChars else { return [line] }
        let characters = Array(line)
        var pieces: [String] = []
        var start = 0
        while start < characters.count {
            let end = min(start + maxChars, characters.count)
            pieces.append(String(characters[start ..< end]))
            start = end
        }
        return pieces
    }
}

#endif
