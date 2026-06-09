//
//  LineChunker.swift
//  SwiftAgents
//
//  A markdown-aware, line-tracking chunker. It picks split points the way qmd
//  does — scored structural boundaries (a heading beats a code-fence beats a
//  horizontal rule beats a blank line beats a list item beats a bare newline),
//  with a squared-distance decay over a look-back window so a heading a little
//  further back still wins over a weak break at the budget edge, and never
//  splits inside a ``` code fence. It still reports the 1-indexed line span
//  each chunk covers, which the store persists as provenance.
//
//  Derived from qmd's scanBreakPoints / findBestCutoff /
//  chunkDocumentWithBreakPoints (github.com/tobi/qmd, src/store.ts).
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
    /// Splits `content` into overlapping, line-numbered chunks, preferring
    /// markdown structure boundaries. `windowChars` is how far back from the
    /// budget edge to hunt for a good break.
    static func chunk(
        _ content: String,
        maxChars: Int = 2000,
        overlapChars: Int = 200,
        windowChars: Int = 800
    ) -> [LineChunk] {
        let chars = Array(content)
        guard !chars.isEmpty else { return [] }
        let budget = max(32, maxChars)
        let overlap = max(0, min(overlapChars, budget / 2))
        let window = max(1, min(windowChars, budget))

        // 1-based source line for every offset (and one past the end).
        var lineOf = [Int](repeating: 1, count: chars.count + 1)
        var line = 1
        for index in chars.indices {
            lineOf[index] = line
            if chars[index] == "\n" { line += 1 }
        }
        lineOf[chars.count] = line

        // Whole document fits in one chunk.
        if chars.count <= budget {
            return [LineChunk(text: content, startLine: 1, endLine: lineOf[chars.count - 1])]
        }

        let breaks = scanBreakPoints(chars)
        let fences = findCodeFences(chars)

        var chunks: [LineChunk] = []
        var start = 0
        while start < chars.count {
            let target = min(start + budget, chars.count)
            var end = target
            if end < chars.count {
                let cut = bestCutoff(breaks: breaks, target: target, window: window, fences: fences)
                if cut > start && cut <= target { end = cut }
            }
            if end <= start { end = min(start + budget, chars.count) }

            chunks.append(LineChunk(
                text: String(chars[start ..< end]),
                startLine: lineOf[start],
                endLine: lineOf[max(start, end - 1)]))

            if end >= chars.count { break }
            // If we cut right at a structural newline, drop it from the boundary
            // so neither chunk carries a stray leading/trailing newline.
            let resume = (chars[end] == "\n") ? end + 1 : end
            var next = resume - overlap
            if next <= start { next = resume }   // guarantee forward progress
            start = next
        }
        return chunks
    }

    // MARK: - Break points

    /// Every newline offset paired with the value of cutting there (the score of
    /// the line that *follows* the newline). Higher is a better split.
    private static func scanBreakPoints(_ chars: [Character]) -> [(pos: Int, score: Int)] {
        var best: [Int: Int] = [:]
        let count = chars.count
        for index in 0 ..< count where chars[index] == "\n" {
            let lineStart = index + 1
            var lineEnd = lineStart
            while lineEnd < count && chars[lineEnd] != "\n" { lineEnd += 1 }
            let score = breakScore(Array(chars[lineStart ..< lineEnd]))
            if score > (best[index] ?? 0) { best[index] = score }
        }
        return best.map { (pos: $0.key, score: $0.value) }.sorted { $0.pos < $1.pos }
    }

    /// Score the line beginning a candidate chunk. Mirrors qmd's BREAK_PATTERNS.
    private static func breakScore(_ line: [Character]) -> Int {
        if line.isEmpty { return 20 }                         // paragraph boundary

        if line[0] == "#" {                                   // heading: #{1..6}(?!#)
            var level = 0
            while level < line.count && line[level] == "#" { level += 1 }
            if (1 ... 6).contains(level) && (level >= line.count || line[level] != "#") {
                return [100, 90, 80, 70, 60, 50][level - 1]
            }
        }
        if line.starts(with: ["`", "`", "`"]) { return 80 }   // code-fence boundary

        let trimmed = String(line).trimmingCharacters(in: .whitespaces)
        if trimmed == "---" || trimmed == "***" || trimmed == "___" { return 60 }  // horizontal rule

        if line.starts(with: ["-", " "]) || line.starts(with: ["*", " "]) { return 5 }  // list item

        var digits = 0                                        // ordered list: `\d+. `
        while digits < line.count && line[digits].isNumber { digits += 1 }
        if digits > 0 && digits + 1 < line.count && line[digits] == "." && line[digits + 1] == " " {
            return 5
        }
        return 1                                              // bare newline
    }

    // MARK: - Code fences

    /// Regions between paired ``` markers; cuts inside them are forbidden.
    private static func findCodeFences(_ chars: [Character]) -> [(start: Int, end: Int)] {
        var regions: [(start: Int, end: Int)] = []
        var inFence = false
        var fenceStart = 0
        let count = chars.count
        for index in 0 ..< count where chars[index] == "\n" {
            guard index + 3 < count,
                  chars[index + 1] == "`", chars[index + 2] == "`", chars[index + 3] == "`" else { continue }
            if inFence {
                regions.append((fenceStart, index + 4))
                inFence = false
            } else {
                fenceStart = index
                inFence = true
            }
        }
        if inFence { regions.append((fenceStart, count)) }
        return regions
    }

    private static func isInsideFence(_ pos: Int, _ fences: [(start: Int, end: Int)]) -> Bool {
        for fence in fences where pos > fence.start && pos < fence.end { return true }
        return false
    }

    // MARK: - Best cutoff

    /// The break offset in `[target - window, target]` maximizing
    /// `score × (1 − (distance/window)² × decay)`; `target` if none qualifies.
    private static func bestCutoff(
        breaks: [(pos: Int, score: Int)],
        target: Int,
        window: Int,
        fences: [(start: Int, end: Int)],
        decay: Double = 0.7
    ) -> Int {
        let windowStart = target - window
        var bestScore = -1.0
        var bestPos = target
        for breakPoint in breaks {
            if breakPoint.pos < windowStart { continue }
            if breakPoint.pos > target { break }
            if isInsideFence(breakPoint.pos, fences) { continue }
            let normalized = Double(target - breakPoint.pos) / Double(window)
            let finalScore = Double(breakPoint.score) * (1.0 - normalized * normalized * decay)
            if finalScore > bestScore {
                bestScore = finalScore
                bestPos = breakPoint.pos
            }
        }
        return bestPos
    }
}

#endif
