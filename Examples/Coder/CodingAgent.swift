import Foundation
import SwiftAgents
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
    let tools: [Tool]
    let toolProviders: [MCPToolProviding]
    let mcpServers: [MCPServerProxy]
    let modelSettings: ModelSettings
    /// Read-only "plan" mode: the mutating tools (`bash`, `write`, `edit`, and the
    /// `apply_patch` builtin) are withheld/refused so the agent can explore and
    /// propose a plan without touching the working tree. Drives ACP session modes.
    let readOnly: Bool

    /// - Parameter isSubAgent: If true, this agent won't spawn its own sub-agent (prevents recursion).
    /// - Parameter readOnly: Plan/read-only mode — see ``readOnly``. Inherited by the sub-agent.
    /// - Parameter reasoningEffort: Reasoning effort for reasoning-capable models (ACP config option).
    /// - Parameter config: RunConfig to use for sub-agent runs (passes model, etc.).
    /// - Parameter mcpServers: Already-connected MCP server proxies whose tools the agent
    ///   exposes alongside its built-ins (e.g. the servers an ACP client configures per session).
    init(
        workingDirectory: String,
        isSubAgent: Bool = false,
        readOnly: Bool = false,
        reasoningEffort: Reasoning.Effort? = nil,
        config: RunConfig = RunConfig(),
        mcpServers: [MCPServerProxy] = []
    ) {
        self.workingDirectory = workingDirectory
        self.mcpServers = mcpServers
        self.readOnly = readOnly
        modelSettings = reasoningEffort.map { ModelSettings(reasoning: Reasoning(effort: $0)) } ?? ModelSettings()

        let model = config.model ?? "gpt-4.1"
        // Plan mode never offers apply_patch (it edits files); the mutating @MCPTool
        // methods stay advertised but refuse at call time (see `ensureWritable`).
        tools = (!readOnly && Tool.supportsApplyPatch(model: model)) ? [.applyPatch] : []

        let role = isSubAgent ? "a sub-agent" : "a coding agent"
        let planNote = readOnly ? """

        You are in PLAN (read-only) mode. Do NOT modify anything: the bash, write,
        edit, and apply_patch tools are disabled and will refuse, and external
        (MCP) tools are withheld. Explore with read, ls, find, and grep, then
        propose a concrete plan of the changes you would make. Tell the user to
        switch to code mode to carry the plan out.
        """ : ""
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
        \(planNote)
        """

        if !isSubAgent {
            let subAgent = CodingAgent(
                workingDirectory: workingDirectory, isSubAgent: true,
                readOnly: readOnly, reasoningEffort: reasoningEffort, config: config
            )
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
        try ensureWritable("bash")
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
        try ensureWritable("write")
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
        try ensureWritable("edit")
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
                    "edits[\(index)].oldText matches \(occurrences) locations in \(path). Must be unique."
                )
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
                "edits[\(index)] overlaps with another edit; merge them into one edit instead"
            )
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
    ) throws -> String {
        let absolutePath = resolve(path ?? ".")
        let maxMatches = max(1, limit ?? 100)
        let rgPath = try Self.locateBinary("rg")

        var args = ["-n", "--color=never", "--hidden", "--no-require-git"]
        if ignoreCase == true { args.append("--ignore-case") }
        if literal == true { args.append("--fixed-strings") }
        if let context, context > 0 { args.append(contentsOf: ["-C", String(context)]) }
        if let glob { args.append(contentsOf: ["--glob", glob]) }
        args.append("--")
        args.append(pattern)
        args.append(absolutePath)

        let result = try Self.runBinary(at: rgPath, arguments: args)
        // rg exits 0 with matches, 1 with no matches, 2 on error.
        if result.exitStatus == 1, result.stdout.isEmpty {
            return "No matches found"
        }
        if result.exitStatus >= 2 {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CoderToolError.message(
                detail.isEmpty ? "rg exited with code \(result.exitStatus)" : detail
            )
        }
        return Self.formatRgOutput(result.stdout,
                                   relativizingFrom: absolutePath,
                                   maxMatches: maxMatches,
                                   byteCap: toolOutputByteCap)
    }

    /// Search for files by glob pattern. Returns matching file paths relative to the search
    /// directory. Respects .gitignore. Output is truncated to 1000 results or 512KB
    /// (whichever is hit first).
    /// - Parameter pattern: Glob pattern to match files, e.g. '*.ts', '**/*.json', or
    ///   'src/**/*.spec.ts'
    /// - Parameter path: Directory to search in (default: current directory)
    /// - Parameter limit: Maximum number of results (default: 1000)
    @MCPTool
    func find(pattern: String, path: String? = nil, limit: Int? = nil) throws -> String {
        let absolutePath = resolve(path ?? ".")
        let maxResults = max(1, limit ?? 1000)
        let fdPath = try Self.locateBinary("fd")

        var args = [
            "--glob",
            "--color=never",
            "--hidden",
            "--no-require-git",
            "--max-results", String(maxResults)
        ]
        // fd matches against the basename by default; switch to
        // full-path matching when the pattern contains `/`, and
        // prepend `**/` so `src/**/*.spec.ts` actually matches
        // anything (matches pi's reference invocation).
        var effectivePattern = pattern
        if pattern.contains("/") {
            args.append("--full-path")
            if !pattern.hasPrefix("/"), !pattern.hasPrefix("**/"), pattern != "**" {
                effectivePattern = "**/" + pattern
            }
        }
        args.append("--")
        args.append(effectivePattern)
        args.append(absolutePath)

        let result = try Self.runBinary(at: fdPath, arguments: args)
        if result.exitStatus >= 2 {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CoderToolError.message(
                detail.isEmpty ? "fd exited with code \(result.exitStatus)" : detail
            )
        }
        var lines = result.stdout.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if lines.isEmpty { return "No files found" }
        let relativized = lines.map { Self.relativize($0, against: absolutePath) }
        let kept = Array(relativized.prefix(maxResults))
        var output = kept.joined(separator: "\n")
        if relativized.count > maxResults {
            output += "\n... (\(relativized.count - maxResults) more files)"
        }
        return output.truncatedForToolOutput(maxLines: maxResults + 1)
    }

    // MARK: - Helpers

    func resolve(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return (workingDirectory as NSString).appendingPathComponent(path)
    }

    /// Refuse a mutating tool while in plan/read-only mode. The message is written
    /// for the model, so it can explain the refusal and offer to switch to code mode.
    private func ensureWritable(_ tool: String) throws {
        if readOnly {
            throw CoderToolError.message(
                "Plan mode is read-only — the `\(tool)` tool is disabled. "
                    + "Switch to code mode (session/set_mode → code) to make changes."
            )
        }
    }

    // MARK: - Subprocess helpers (rg / fd shellouts)

    /// Combined stdout/stderr/exit-status capture for a single
    /// rg / fd run — same shape the grep / find tools post-process.
    struct CapturedRun {
        let stdout: String
        let stderr: String
        let exitStatus: Int32
    }

    /// Locate `name` (typically `rg` or `fd`) on the process's `PATH`.
    /// Walks `$PATH` directly rather than spawning `which` so the
    /// lookup stays a single syscall sweep with no fork. Throws a
    /// CoderToolError carrying installation guidance when the binary
    /// isn't reachable — message ends up in front of the model so it
    /// doesn't quietly fall back to something dumb.
    static func locateBinary(_ name: String) throws -> String {
        let env = ProcessInfo.processInfo.environment
        let pathList = env["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        let fileManager = FileManager.default
        for directory in pathList.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = (String(directory) as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw CoderToolError.message(missingBinaryHint(for: name))
    }

    /// Install guidance the model sees when `rg` / `fd` aren't on
    /// PATH. Phrased so the agent can either tell the user how to
    /// install the tool or pick a different approach.
    private static func missingBinaryHint(for binary: String) -> String {
        switch binary {
            case "rg":
                return """
                `rg` (ripgrep) is required by the grep tool but isn't on PATH.
                  • macOS:   brew install ripgrep
                  • Linux:   apt install ripgrep   (or your distro's package manager)
                  • Source:  https://github.com/BurntSushi/ripgrep/releases
                """
            case "fd":
                return """
                `fd` is required by the find tool but isn't on PATH.
                  • macOS:   brew install fd
                  • Linux:   apt install fd-find    (binary is `fdfind` on Debian/Ubuntu — symlink to `fd`)
                  • Source:  https://github.com/sharkdp/fd/releases
                """
            default:
                return "`\(binary)` is required but isn't on PATH."
        }
    }

    /// Spawn `executable` with `arguments`, capturing stdout and
    /// stderr on separate pipes so we can keep them distinct in the
    /// post-processing layer. Throws when `Process.run()` itself
    /// fails (typically permissions or unreadable binary); a non-zero
    /// exit status is returned to the caller for tool-specific
    /// interpretation (rg uses 1 for "no matches", which is success
    /// shaped).
    static func runBinary(at executable: String, arguments: [String]) throws -> CapturedRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw CoderToolError.message(
                "failed to invoke \(executable): \(error.localizedDescription)"
            )
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CapturedRun(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitStatus: process.terminationStatus
        )
    }

    /// Walk rg's `path:line:content` / `path-line-content` stream,
    /// relativizing each path against the search root, capping single
    /// lines at 1024 chars (per the tool description), and stopping
    /// at `maxMatches` match lines (context lines don't count toward
    /// the limit). Bounded by `byteCap` total bytes.
    static func formatRgOutput(
        _ rawStdout: String,
        relativizingFrom searchRoot: String,
        maxMatches: Int,
        byteCap: Int
    ) -> String {
        var lines = rawStdout.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        var output: [String] = []
        var totalBytes = 0
        var matchCount = 0

        for line in lines {
            let isGroupBreak = line == "--"
            let (relativized, isMatchLine) = isGroupBreak
                ? (line, false)
                : Self.rewriteRgLine(line, searchRoot: searchRoot)
            let truncated: String = if isGroupBreak || relativized.count <= 1024 {
                relativized
            } else {
                String(relativized.prefix(1024)) + "…"
            }
            let bytes = truncated.utf8.count + 1
            if totalBytes + bytes > byteCap { break }
            if isMatchLine {
                if matchCount >= maxMatches { break }
                matchCount += 1
            }
            output.append(truncated)
            totalBytes += bytes
        }

        var didTruncate = output.count < lines.count
        if !didTruncate, matchCount >= maxMatches { didTruncate = true }
        if didTruncate {
            output.append("... (more matches truncated; limit=\(maxMatches))")
        }
        return output.isEmpty ? "No matches found" : output.joined(separator: "\n")
    }

    /// Split a single rg output line into `(path)(sep)(line)(sep)(content)`,
    /// rewrite the absolute `path` to be relative to `searchRoot`, then
    /// reassemble. Returns `(rewritten, isMatchLine)` — `:` separator
    /// means a real match; `-` means a context line.
    private static func rewriteRgLine(_ line: String, searchRoot: String) -> (String, Bool) {
        // rg's format is `<path><sep><lineno><sep><content>` where `<sep>`
        // is `:` for match lines and `-` for context lines. We only need
        // to rewrite the leading <path> chunk; the rest passes through
        // untouched.
        let separators: [Character] = [":", "-"]
        for separator in separators {
            // Find the first separator that's followed by an all-digit
            // run terminated by the same separator — that's the
            // <path><sep><lineno><sep> boundary, vs. a `:` that's just
            // part of the path or content.
            var search = line.startIndex
            while let sepIdx = line[search...].firstIndex(of: separator) {
                let afterSep = line.index(after: sepIdx)
                guard let nextSep = line[afterSep...].firstIndex(of: separator) else { break }
                let between = line[afterSep ..< nextSep]
                if !between.isEmpty, between.allSatisfy(\.isNumber) {
                    let pathPart = String(line[line.startIndex ..< sepIdx])
                    let rest = String(line[sepIdx...])
                    let relPath = relativize(pathPart, against: searchRoot)
                    return (relPath + rest, separator == ":")
                }
                search = afterSep
            }
        }
        return (line, false)
    }

    /// Make `path` relative to `root` for display. Falls through to
    /// the original string when `path` isn't under `root` (e.g. the
    /// user passed an explicit file outside the workdir).
    static func relativize(_ path: String, against root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(prefix) {
            let trimmed = String(path.dropFirst(prefix.count))
            return trimmed.isEmpty ? "." : trimmed
        }
        if path == root { return "." }
        return path
    }
}
