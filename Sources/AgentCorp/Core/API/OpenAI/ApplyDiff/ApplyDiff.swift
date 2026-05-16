/// V4A diff parser and applicator.
///
/// Ported from the OpenAI Agents Python SDK `apply_diff.py`.
/// Supports both create-file syntax (only "+" prefixed lines)
/// and update syntax with context hunks.

import Foundation

public enum ApplyDiffMode {
	case `default`
	case create
}

public enum ApplyDiffError: LocalizedError {
	case invalidAddFileLine(String)
	case invalidLine(String)
	case invalidContext(Int, String)
	case invalidEOFContext(Int, String)
	case emptySection(Int, String)
	case chunkOutOfBounds(Int, Int)
	case overlappingDiffChunk(Int, Int)

	public var errorDescription: String? {
		switch self {
		case .invalidAddFileLine(let line): return "Invalid Add File Line: \(line)"
		case .invalidLine(let line): return "Invalid Line: \(line)"
		case .invalidContext(let cursor, let ctx): return "Invalid Context \(cursor):\n\(ctx)"
		case .invalidEOFContext(let cursor, let ctx): return "Invalid EOF Context \(cursor):\n\(ctx)"
		case .emptySection(let index, let line): return "Nothing in this section - index=\(index) \(line)"
		case .chunkOutOfBounds(let idx, let len): return "applyDiff: chunk.origIndex \(idx) > input length \(len)"
		case .overlappingDiffChunk(let idx, let cursor): return "applyDiff: overlapping chunk at \(idx) (cursor \(cursor))"
		}
	}
}

// MARK: - Data Types

private struct DiffChunk {
	var origIndex: Int
	var delLines: [String]
	var insLines: [String]
}

private class ParserState {
	var lines: [String]
	var index: Int = 0
	var fuzz: Int = 0

	init(lines: [String]) {
		self.lines = lines
	}
}

private struct ReadSectionResult {
	var nextContext: [String]
	var sectionDiffChunks: [DiffChunk]
	var endIndex: Int
	var eof: Bool
}

private struct ContextMatch {
	var newIndex: Int
	var fuzz: Int
}

// MARK: - Constants

private let END_PATCH = "*** End Patch"
private let END_FILE = "*** End of File"
private let SECTION_TERMINATORS = [
	END_PATCH,
	"*** Update File:",
	"*** Delete File:",
	"*** Add File:",
]
private let END_SECTION_MARKERS = SECTION_TERMINATORS + [END_FILE]

// MARK: - Public API

/// Apply a V4A diff to the provided text.
public func applyDiff(input: String, diff: String, mode: ApplyDiffMode = .default) throws -> String {
	let newline = detectNewline(input: input, diff: diff, mode: mode)
	let diffLines = normalizeDiffLines(diff)

	if case .create = mode {
		return try parseCreateDiff(diffLines, newline: newline)
	}

	let normalizedInput = input.replacingOccurrences(of: "\r\n", with: "\n")
	let chunks = try parseUpdateDiff(diffLines, input: normalizedInput)
	return try applyDiffChunks(normalizedInput, chunks: chunks, newline: newline)
}

// MARK: - Helpers

private func normalizeDiffLines(_ diff: String) -> [String] {
	var lines = diff.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
	if let last = lines.last, last.isEmpty { lines.removeLast() }
	return lines
}

private func detectNewline(input: String, diff: String, mode: ApplyDiffMode) -> String {
	if case .default = mode, input.contains("\n") {
		return input.contains("\r\n") ? "\r\n" : "\n"
	}
	return diff.contains("\r\n") ? "\r\n" : "\n"
}

private func isDone(_ state: ParserState, prefixes: [String]) -> Bool {
	guard state.index < state.lines.count else { return true }
	let current = state.lines[state.index]
	return prefixes.contains(where: { current.hasPrefix($0) })
}

private func readStr(_ state: ParserState, prefix: String) -> String {
	guard state.index < state.lines.count else { return "" }
	let current = state.lines[state.index]
	if current.hasPrefix(prefix) {
		state.index += 1
		return String(current.dropFirst(prefix.count))
	}
	return ""
}

// MARK: - Create Diff

private func parseCreateDiff(_ lines: [String], newline: String) throws -> String {
	let parser = ParserState(lines: lines + [END_PATCH])
	var output = [String]()

	while !isDone(parser, prefixes: SECTION_TERMINATORS) {
		guard parser.index < parser.lines.count else { break }
		let line = parser.lines[parser.index]
		parser.index += 1
		guard line.hasPrefix("+") else {
			throw ApplyDiffError.invalidAddFileLine(line)
		}
		output.append(String(line.dropFirst()))
	}

	return output.joined(separator: newline)
}

// MARK: - Update Diff

private func parseUpdateDiff(_ lines: [String], input: String) throws -> [DiffChunk] {
	let parser = ParserState(lines: lines + [END_PATCH])
	let inputLines = input.components(separatedBy: "\n")
	var chunks = [DiffChunk]()
	var cursor = 0

	while !isDone(parser, prefixes: END_SECTION_MARKERS) {
		let anchor = readStr(parser, prefix: "@@ ")
		let hasBareAnchor = anchor.isEmpty
			&& parser.index < parser.lines.count
			&& parser.lines[parser.index] == "@@"
		if hasBareAnchor { parser.index += 1 }

		if !(!anchor.isEmpty || hasBareAnchor || cursor == 0) {
			let currentLine = parser.index < parser.lines.count ? parser.lines[parser.index] : ""
			throw ApplyDiffError.invalidLine(currentLine)
		}

		if !anchor.trimmingCharacters(in: .whitespaces).isEmpty {
			cursor = advanceCursorToAnchor(anchor, inputLines: inputLines, cursor: cursor, parser: parser)
		}

		let section = try readSection(parser.lines, startIndex: parser.index)
		let findResult = findContext(inputLines, context: section.nextContext, start: cursor, eof: section.eof)

		if findResult.newIndex == -1 {
			let ctxText = section.nextContext.joined(separator: "\n")
			if section.eof {
				throw ApplyDiffError.invalidEOFContext(cursor, ctxText)
			}
			throw ApplyDiffError.invalidContext(cursor, ctxText)
		}

		cursor = findResult.newIndex + section.nextContext.count
		parser.fuzz += findResult.fuzz
		parser.index = section.endIndex

		for ch in section.sectionDiffChunks {
			chunks.append(DiffChunk(
				origIndex: ch.origIndex + findResult.newIndex,
				delLines: ch.delLines,
				insLines: ch.insLines
			))
		}
	}

	return chunks
}

private func advanceCursorToAnchor(_ anchor: String, inputLines: [String], cursor: Int, parser: ParserState) -> Int {
	var cursor = cursor
	var found = false

	if !inputLines[0..<cursor].contains(where: { $0 == anchor }) {
		for i in cursor..<inputLines.count {
			if inputLines[i] == anchor {
				cursor = i + 1
				found = true
				break
			}
		}
	}

	let trimmedAnchor = anchor.trimmingCharacters(in: .whitespaces)
	if !found && !inputLines[0..<cursor].contains(where: { $0.trimmingCharacters(in: .whitespaces) == trimmedAnchor }) {
		for i in cursor..<inputLines.count {
			if inputLines[i].trimmingCharacters(in: .whitespaces) == trimmedAnchor {
				cursor = i + 1
				parser.fuzz += 1
				found = true
				break
			}
		}
	}

	return cursor
}

private func readSection(_ lines: [String], startIndex: Int) throws -> ReadSectionResult {
	var context = [String]()
	var delLines = [String]()
	var insLines = [String]()
	var sectionDiffChunks = [DiffChunk]()

	enum Mode { case keep, add, delete }
	var mode: Mode = .keep
	var index = startIndex
	let origIndex = index

	while index < lines.count {
		let raw = lines[index]

		if raw.hasPrefix("@@") || raw.hasPrefix(END_PATCH)
			|| raw.hasPrefix("*** Update File:") || raw.hasPrefix("*** Delete File:")
			|| raw.hasPrefix("*** Add File:") || raw.hasPrefix(END_FILE) {
			break
		}
		if raw == "***" { break }
		if raw.hasPrefix("***") {
			throw ApplyDiffError.invalidLine(raw)
		}

		index += 1
		let lastMode = mode
		let line = raw.isEmpty ? " " : raw
		let prefix = line[line.startIndex]

		switch prefix {
		case "+": mode = .add
		case "-": mode = .delete
		case " ": mode = .keep
		default:
			throw ApplyDiffError.invalidLine(line)
		}

		let lineContent = String(line.dropFirst())
		let switchingToContext = mode == .keep && lastMode != .keep

		if switchingToContext && (!delLines.isEmpty || !insLines.isEmpty) {
			sectionDiffChunks.append(DiffChunk(
				origIndex: context.count - delLines.count,
				delLines: delLines,
				insLines: insLines
			))
			delLines = []
			insLines = []
		}

		switch mode {
		case .delete:
			delLines.append(lineContent)
			context.append(lineContent)
		case .add:
			insLines.append(lineContent)
		case .keep:
			context.append(lineContent)
		}
	}

	if !delLines.isEmpty || !insLines.isEmpty {
		sectionDiffChunks.append(DiffChunk(
			origIndex: context.count - delLines.count,
			delLines: delLines,
			insLines: insLines
		))
	}

	if index < lines.count && lines[index] == END_FILE {
		return ReadSectionResult(nextContext: context, sectionDiffChunks: sectionDiffChunks, endIndex: index + 1, eof: true)
	}

	if index == origIndex {
		let nextLine = index < lines.count ? lines[index] : ""
		throw ApplyDiffError.emptySection(index, nextLine)
	}

	return ReadSectionResult(nextContext: context, sectionDiffChunks: sectionDiffChunks, endIndex: index, eof: false)
}

// MARK: - Context Matching

private func findContext(_ lines: [String], context: [String], start: Int, eof: Bool) -> ContextMatch {
	if eof {
		let endStart = max(0, lines.count - context.count)
		let endMatch = findContextCore(lines, context: context, start: endStart)
		if endMatch.newIndex != -1 { return endMatch }
		let fallback = findContextCore(lines, context: context, start: start)
		return ContextMatch(newIndex: fallback.newIndex, fuzz: fallback.fuzz + 10000)
	}
	return findContextCore(lines, context: context, start: start)
}

private func findContextCore(_ lines: [String], context: [String], start: Int) -> ContextMatch {
	guard !context.isEmpty else {
		return ContextMatch(newIndex: start, fuzz: 0)
	}

	// Exact match
	for i in start..<lines.count {
		if equalsSlice(lines, target: context, start: i, map: { $0 }) {
			return ContextMatch(newIndex: i, fuzz: 0)
		}
	}
	// Trailing whitespace fuzz
	for i in start..<lines.count {
		if equalsSlice(lines, target: context, start: i, map: { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }) {
			return ContextMatch(newIndex: i, fuzz: 1)
		}
	}
	// Full whitespace fuzz
	for i in start..<lines.count {
		if equalsSlice(lines, target: context, start: i, map: { $0.trimmingCharacters(in: .whitespaces) }) {
			return ContextMatch(newIndex: i, fuzz: 100)
		}
	}

	return ContextMatch(newIndex: -1, fuzz: 0)
}

private func equalsSlice(_ source: [String], target: [String], start: Int, map: (String) -> String) -> Bool {
	guard start + target.count <= source.count else { return false }
	for (offset, targetValue) in target.enumerated() {
		if map(source[start + offset]) != map(targetValue) { return false }
	}
	return true
}

// MARK: - Apply DiffChunks

private func applyDiffChunks(_ input: String, chunks: [DiffChunk], newline: String) throws -> String {
	let origLines = input.components(separatedBy: "\n")
	var destLines = [String]()
	var cursor = 0

	for chunk in chunks {
		guard chunk.origIndex <= origLines.count else {
			throw ApplyDiffError.chunkOutOfBounds(chunk.origIndex, origLines.count)
		}
		guard cursor <= chunk.origIndex else {
			throw ApplyDiffError.overlappingDiffChunk(chunk.origIndex, cursor)
		}

		destLines.append(contentsOf: origLines[cursor..<chunk.origIndex])
		cursor = chunk.origIndex

		destLines.append(contentsOf: chunk.insLines)
		cursor += chunk.delLines.count
	}

	destLines.append(contentsOf: origLines[cursor...])
	return destLines.joined(separator: newline)
}
