import Foundation
import Providers
import SwiftMCP

/// One targeted edit inside a multi-edit `edit` call. The struct shape
/// (rather than parallel `oldTexts`/`newTexts` arrays) keeps each pair
/// in a single JSON object the model can read top-to-bottom.
@Schema
struct Edit: Codable, Sendable {
    /// Exact text for one targeted replacement. It must be unique in
    /// the original file and must not overlap with any other
    /// edits[].oldText in the same call.
    let oldText: String
    /// Replacement text for this targeted edit.
    let newText: String
}

@MCPServer
final class CodingAgent: Agent, @unchecked Sendable {
    typealias OutputType = String

    let name = "Coder"
    let instructions: String
    let workingDirectory: String
    private let gitIgnore: GitIgnore
    let tools: [Tool]
    let toolProviders: [MCPToolProviding]

    /// - Parameter isSubAgent: If true, this agent won't spawn its own sub-agent (prevents recursion).
    /// - Parameter config: RunConfig to use for sub-agent runs (passes model, etc.).
    init(workingDirectory: String, isSubAgent: Bool = false, config: RunConfig = RunConfig()) {
        self.workingDirectory = workingDirectory
        gitIgnore = GitIgnore(workingDirectory: workingDirectory)

        let model = config.model ?? "gpt-4.1"
        tools = Tool.supportsApplyPatch(model: model) ? [.applyPatch] : []

        let role = isSubAgent ? "a sub-agent" : "a coding agent"
        instructions = """
        You are \(role) working in: \(workingDirectory)

        Use your tools to explore, understand, and modify the project. Be concise.

        Guidelines:
        - Always read a file before editing it.
        - Use bash for git, build, test, and other shell operations.
        - Use edit for targeted changes. Use write only for new files or complete rewrites.
        - Use ls, find, and grep to explore the project structure and search for code.
        - Keep tool outputs short. If output is truncated, use offset/limit to paginate.
        - Never wrap tool output in triple-backtick code blocks. Present results as plain text.
        - When done, summarize what you did.
        \(isSubAgent ? "" : "- Use sub_agent for exploration or research tasks to keep your own context clean.")
        """

        if !isSubAgent {
            let subAgent = CodingAgent(workingDirectory: workingDirectory, isSubAgent: true, config: config)
            let subAgentProvider = subAgent.asToolProvider(
                toolName: "sub_agent",
                toolDescription: """
                Delegate a task to a sub-agent that has its own tools and conversation. \
                Use this for exploration, research, or complex multi-step tasks that would \
                clutter your own context. The sub-agent has the same tools as you. Pass a \
                clear, self-contained request as input. Returns the sub-agent's final text response.
                """,
                config: config
            )
            toolProviders = [subAgentProvider]
        } else {
            toolProviders = []
        }
    }

    // MARK: - Tools

    /// Execute a bash command in the current working directory. Returns stdout and stderr.
    /// Output is truncated to last 2000 lines or 512KB (whichever is hit first). Optionally
    /// provide a timeout in seconds.
    /// - Parameter command: Bash command to execute
    /// - Parameter timeout: Timeout in seconds (optional, no default timeout)
    @MCPTool
    func bash(command: String, timeout: Int? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        let timeoutSeconds = timeout ?? 0

        if timeoutSeconds > 0 {
            let deadline = DispatchTime.now() + .seconds(timeoutSeconds)
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning { process.terminate() }
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        let status = process.terminationStatus

        if status != 0 {
            return output.truncatedForToolOutputTail() + "\n\nCommand exited with code \(status)"
        }

        return (output.isEmpty ? "(no output)" : output).truncatedForToolOutputTail()
    }

    /// Read the contents of a file. For text files, output is truncated to 2000 lines or
    /// 512KB (whichever is hit first). Use offset/limit for large files. When you need the
    /// full file, continue with offset until complete.
    /// - Parameter path: Path to the file to read (relative or absolute)
    /// - Parameter offset: Line number to start reading from (1-indexed)
    /// - Parameter limit: Maximum number of lines to read
    @MCPTool
    func read(path: String, offset: Int? = nil, limit: Int? = nil) throws -> String {
        let absolutePath = resolve(path)
        let content = try String(contentsOfFile: absolutePath, encoding: .utf8)
        let allLines = content.components(separatedBy: "\n")

        let startLine = max(0, (offset ?? 1) - 1)

        guard startLine < allLines.count else {
            throw CoderToolError.message("Offset \(offset ?? 1) is beyond end of file (\(allLines.count) lines)")
        }

        let selected: [String]
        if let limit {
            let endLine = min(startLine + limit, allLines.count)
            selected = Array(allLines[startLine ..< endLine])
        } else {
            selected = Array(allLines[startLine...])
        }

        let output = selected.joined(separator: "\n").truncatedForToolOutput()

        let shownCount = selected.count
        let remaining = allLines.count - (startLine + shownCount)
        if remaining > 0 {
            let nextOffset = startLine + shownCount + 1
            return output + "\n\n[\(remaining) more lines. Use offset=\(nextOffset) to continue.]"
        }

        return output
    }

    /// Write content to a file. Creates the file if it doesn't exist, overwrites if it does.
    /// Automatically creates parent directories.
    /// - Parameter path: Path to the file to write (relative or absolute)
    /// - Parameter content: Content to write to the file
    @MCPTool
    func write(path: String, content: String) throws -> String {
        let absolutePath = resolve(path)
        let dir = (absolutePath as NSString).deletingLastPathComponent

        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try content.write(toFile: absolutePath, atomically: true, encoding: .utf8)

        return "Wrote \(content.utf8.count) bytes to \(path)"
    }

    /// Edit a single file using exact text replacement. Every edits[].oldText must match a
    /// unique, non-overlapping region of the original file. If two changes affect the same
    /// block or nearby lines, merge them into one edit instead of emitting overlapping
    /// edits. Do not include large unchanged regions just to connect distant changes.
    /// - Parameter path: Path to the file to edit (relative or absolute)
    /// - Parameter edits: One or more targeted replacements. Each edit is matched against
    ///   the original file, not incrementally. Do not include overlapping or nested edits.
    ///   If two changes touch the same block or nearby lines, merge them into one edit
    ///   instead.
    @MCPTool
    func edit(path: String, edits: [Edit]) throws -> String {
        guard !edits.isEmpty else {
            throw CoderToolError.message("edits must not be empty")
        }
        let absolutePath = resolve(path)
        let original = try String(contentsOfFile: absolutePath, encoding: .utf8)

        struct Resolved {
            let range: Range<String.Index>
            let newText: String
        }

        // Validate uniqueness in the ORIGINAL file (per the contract) and
        // capture each edit's range up-front.
        var resolved: [Resolved] = []
        for (index, edit) in edits.enumerated() {
            let occurrences = original.components(separatedBy: edit.oldText).count - 1
            guard occurrences > 0 else {
                throw CoderToolError.message("edits[\(index)].oldText not found in \(path)")
            }
            guard occurrences == 1 else {
                throw CoderToolError.message(
                    "edits[\(index)].oldText matches \(occurrences) locations in \(path). Must be unique.")
            }
            guard let range = original.range(of: edit.oldText) else {
                throw CoderToolError.message("edits[\(index)].oldText could not be located in \(path)")
            }
            resolved.append(Resolved(range: range, newText: edit.newText))
        }

        // Sort by position, then check pairwise non-overlap.
        resolved.sort { $0.range.lowerBound < $1.range.lowerBound }
        for index in 1 ..< resolved.count
            where resolved[index].range.lowerBound < resolved[index - 1].range.upperBound {
            throw CoderToolError.message(
                "edits[\(index)] overlaps with another edit; merge them into one edit instead")
        }

        // Stitch the new file in one pass — no incremental mutation, so
        // later edits' indices into the ORIGINAL stay valid.
        var output = ""
        var cursor = original.startIndex
        for edit in resolved {
            output.append(contentsOf: original[cursor ..< edit.range.lowerBound])
            output.append(edit.newText)
            cursor = edit.range.upperBound
        }
        output.append(contentsOf: original[cursor ..< original.endIndex])

        try output.write(toFile: absolutePath, atomically: true, encoding: .utf8)
        return edits.count == 1 ? "Edited \(path)" : "Edited \(path) (\(edits.count) changes)"
    }

    /// List directory contents. Returns entries sorted alphabetically, with '/' suffix for
    /// directories. Includes dotfiles. Output is truncated to 500 entries or 512KB
    /// (whichever is hit first).
    /// - Parameter path: Directory to list (default: current directory)
    /// - Parameter limit: Maximum number of entries to return (default: 500)
    @MCPTool
    func ls(path: String? = nil, limit: Int? = nil) -> String {
        let dir = resolve(path ?? ".")

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "Error: Directory not found: \(path ?? ".")"
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return "Error: Cannot read directory: \(path ?? ".")"
        }

        let maxEntries = max(1, limit ?? 500)
        var lines = [String]()
        for entry in entries.sorted().prefix(maxEntries) {
            var isDir: ObjCBool = false
            let fullPath = (dir as NSString).appendingPathComponent(entry)
            FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
            lines.append(isDir.boolValue ? "\(entry)/" : entry)
        }
        if entries.count > maxEntries {
            lines.append("... (\(entries.count - maxEntries) more entries)")
        }

        return lines.isEmpty
            ? "(empty directory)"
            : lines.joined(separator: "\n").truncatedForToolOutput(maxLines: maxEntries)
    }

    /// Search file contents for a pattern. Returns matching lines with file paths and line
    /// numbers. Respects .gitignore. Output is truncated to 100 matches or 512KB (whichever
    /// is hit first). Long lines are truncated to 1024 chars.
    /// - Parameter pattern: Search pattern (regex or literal string)
    /// - Parameter path: Directory or file to search (default: current directory)
    /// - Parameter glob: Filter files by glob pattern, e.g. '*.ts' or '**/*.spec.ts'
    /// - Parameter ignoreCase: Case-insensitive search (default: false)
    /// - Parameter literal: Treat pattern as literal string instead of regex (default: false)
    /// - Parameter context: Number of lines to show before and after each match (default: 0)
    /// - Parameter limit: Maximum number of matches to return (default: 100)
    @MCPTool
    func grep(
        pattern: String,
        path: String? = nil,
        glob: String? = nil,
        ignoreCase: Bool? = nil,
        literal: Bool? = nil,
        context: Int? = nil,
        limit: Int? = nil
    ) -> String {
        let relativePath = relativize(path ?? ".")
        let dir = resolve(relativePath)
        let excludeDirs = Set(gitIgnore.excludeDirs)
        let excludeFiles = Set(gitIgnore.excludeFiles)
        let fileManager = FileManager.default
        let maxMatches = max(1, limit ?? 100)
        let contextLines = max(0, context ?? 0)

        let regexSource = literal == true
            ? NSRegularExpression.escapedPattern(for: pattern)
            : pattern
        let options: NSRegularExpression.Options = ignoreCase == true ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: regexSource, options: options) else {
            return "Error: Invalid regex pattern: \(pattern)"
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dir, isDirectory: &isDirectory) else {
            return "Error: Path not found: \(relativePath)"
        }

        var output = [String]()
        var matchCount = 0
        var totalBytes = 0
        let byteCap = toolOutputByteCap
        var previousFile: String?

        func emit(filePath: String, kind: GrepLineKind, lineNumber: Int, line: String) -> Bool {
            // Cap any single line so a binary or minified blob can't blow the byte budget alone.
            let capped = line.count > 1024 ? String(line.prefix(1024)) + "…" : line
            // grep convention: matches separated by `:`, context by `-`,
            // a `--` between non-adjacent groups.
            let separator: Character = kind == .match ? ":" : "-"
            let prefix: String
            if let previousFile, previousFile != filePath {
                prefix = "--\n"
            } else {
                prefix = ""
            }
            previousFile = filePath
            let line = "\(prefix)\(filePath)\(separator)\(lineNumber)\(separator)\(capped)"
            let bytes = line.utf8.count + 1
            if totalBytes + bytes > byteCap { return false }
            output.append(line)
            totalBytes += bytes
            return true
        }

        if !isDirectory.boolValue {
            let matches = searchFile(atPath: dir, regex: regex, contextLines: contextLines)
            for entry in matches {
                if entry.kind == .match { matchCount += 1 }
                if matchCount > maxMatches { break }
                if !emit(filePath: relativePath, kind: entry.kind,
                         lineNumber: entry.lineNumber, line: entry.line) { break }
            }
        } else {
            guard let enumerator = fileManager.enumerator(atPath: dir) else {
                return "Error: Cannot read directory: \(relativePath)"
            }

            let globPattern = glob?.replacingOccurrences(of: "**/", with: "")

            enumerate: while let entry = enumerator.nextObject() as? String {
                let fileName = (entry as NSString).lastPathComponent

                if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                    if excludeDirs.contains(fileName) || fileName.hasPrefix(".") {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if excludeFiles.contains(where: { fnmatch($0, fileName, 0) == 0 }) {
                    continue
                }

                if let globPattern, fnmatch(globPattern, fileName, 0) != 0 {
                    continue
                }

                let filePath = (dir as NSString).appendingPathComponent(entry)
                let displayPath = relativePath == "."
                    ? entry
                    : (relativePath as NSString).appendingPathComponent(entry)
                let matches = searchFile(atPath: filePath, regex: regex, contextLines: contextLines)

                for hit in matches {
                    if hit.kind == .match { matchCount += 1 }
                    if matchCount > maxMatches { break enumerate }
                    if !emit(filePath: displayPath, kind: hit.kind,
                             lineNumber: hit.lineNumber, line: hit.line) {
                        break enumerate
                    }
                }
            }
        }

        if matchCount > maxMatches {
            output.append("... (more matches truncated; limit=\(maxMatches))")
        }
        return output.isEmpty ? "No matches found" : output.joined(separator: "\n")
    }

    /// One emitted grep line — either a real match or a context line. The
    /// distinction drives the `:` vs `-` separator real grep uses.
    private enum GrepLineKind { case match, context }
    private struct GrepHit {
        let lineNumber: Int
        let line: String
        let kind: GrepLineKind
    }

    /// Search a single file for regex matches plus optional context. Returns
    /// hits in line order so the caller can stream them straight to the
    /// output buffer without resorting.
    private func searchFile(
        atPath path: String,
        regex: NSRegularExpression,
        contextLines: Int
    ) -> [GrepHit] {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else { return [] }

        let lines = content.components(separatedBy: "\n")
        var matchedIndices: [Int] = []
        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            if regex.firstMatch(in: line, range: range) != nil {
                matchedIndices.append(index)
            }
        }
        guard !matchedIndices.isEmpty else { return [] }

        if contextLines == 0 {
            return matchedIndices.map { GrepHit(lineNumber: $0 + 1, line: lines[$0], kind: .match) }
        }

        let matchSet = Set(matchedIndices)
        var included = Set<Int>()
        for index in matchedIndices {
            let low = max(0, index - contextLines)
            let high = min(lines.count - 1, index + contextLines)
            for offset in low ... high { included.insert(offset) }
        }
        return included.sorted().map { index in
            GrepHit(lineNumber: index + 1,
                    line: lines[index],
                    kind: matchSet.contains(index) ? .match : .context)
        }
    }

    /// Search for files by glob pattern. Returns matching file paths relative to the search
    /// directory. Respects .gitignore. Output is truncated to 1000 results or 512KB
    /// (whichever is hit first).
    /// - Parameter pattern: Glob pattern to match files, e.g. '*.ts', '**/*.json', or
    ///   'src/**/*.spec.ts'
    /// - Parameter path: Directory to search in (default: current directory)
    /// - Parameter limit: Maximum number of results (default: 1000)
    @MCPTool
    func find(pattern: String, path: String? = nil, limit: Int? = nil) -> String {
        let relativePath = relativize(path ?? ".")
        let dir = resolve(relativePath)
        let excludeDirs = Set(gitIgnore.excludeDirs)
        let fileManager = FileManager.default
        let maxResults = max(1, limit ?? 1000)

        guard let enumerator = fileManager.enumerator(atPath: dir) else {
            return "Error: Cannot read directory: \(relativePath)"
        }

        // Strip **/ prefix since we already recurse
        let effectivePattern = pattern.replacingOccurrences(of: "**/", with: "")
        let matchAgainstPath = effectivePattern.contains("/")
        var results = [String]()

        while let entry = enumerator.nextObject() as? String {
            let fileName = (entry as NSString).lastPathComponent

            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                if excludeDirs.contains(fileName) || fileName.hasPrefix(".") {
                    enumerator.skipDescendants()
                    continue
                }
            }

            let matchTarget = matchAgainstPath ? entry : fileName
            if fnmatch(effectivePattern, matchTarget, 0) == 0 {
                let resultPath = relativePath == "."
                    ? entry
                    : (relativePath as NSString).appendingPathComponent(entry)
                results.append(resultPath)
                if results.count >= maxResults { break }
            }
        }

        return (results.isEmpty ? "No files found" : results.joined(separator: "\n"))
            .truncatedForToolOutput(maxLines: maxResults)
    }

    /// Converts an absolute path to a path relative to the working directory. Passes through relative paths unchanged.
    private func relativize(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let prefix = workingDirectory.hasSuffix("/") ? workingDirectory : workingDirectory + "/"
        if path.hasPrefix(prefix) {
            let relative = String(path.dropFirst(prefix.count))
            return relative.isEmpty ? "." : relative
        }
        if path == workingDirectory {
            return "."
        }
        return path
    }

    // MARK: - Helpers

    func resolve(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return (workingDirectory as NSString).appendingPathComponent(path)
    }
}
