import Foundation
import Providers
import SwiftMCP

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
		self.gitIgnore = GitIgnore(workingDirectory: workingDirectory)

		let model = config.model ?? "gpt-4.1"
		self.tools = Tool.supportsApplyPatch(model: model) ? [.applyPatch] : []

		let role = isSubAgent ? "a sub-agent" : "a coding agent"
		self.instructions = """
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
				toolDescription: "Delegate a task to a sub-agent that has its own tools and conversation. Use this for exploration, research, or complex multi-step tasks that would clutter your own context. The sub-agent has the same tools as you. Pass a clear, self-contained request as input. Returns the sub-agent's final text response.",
				config: config
			)
			self.toolProviders = [subAgentProvider]
		} else {
			self.toolProviders = []
		}
	}

	// MARK: - Tools

	/// Execute a bash command in the working directory. Returns stdout and stderr combined.
	/// - Parameter command: Bash command to execute
	/// - Parameter timeout: Timeout in seconds (optional, default: no timeout)
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
			return output.truncatedForToolOutput() + "\n\nCommand exited with code \(status)"
		}

		return (output.isEmpty ? "(no output)" : output).truncatedForToolOutput()
	}

	/// Read the contents of a file. Use offset/limit for large files.
	/// - Parameter path: Path to the file (relative or absolute)
	/// - Parameter offset: Line number to start reading from (1-indexed, optional)
	/// - Parameter limit: Maximum number of lines to read (optional)
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
			selected = Array(allLines[startLine..<endLine])
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

	/// Write content to a file. Creates the file and parent directories if they don't exist. Overwrites existing files.
	/// - Parameter path: Path to the file (relative or absolute)
	/// - Parameter content: Content to write to the file
	@MCPTool
	func write(path: String, content: String) throws -> String {
		let absolutePath = resolve(path)
		let dir = (absolutePath as NSString).deletingLastPathComponent

		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		try content.write(toFile: absolutePath, atomically: true, encoding: .utf8)

		return "Wrote \(content.utf8.count) bytes to \(path)"
	}

	/// Edit a file using exact text replacement. Each oldText must match a unique region in the file.
	/// - Parameter path: Path to the file (relative or absolute)
	/// - Parameter oldText: Exact text to find (must be unique in the file)
	/// - Parameter newText: Replacement text
	@MCPTool
	func edit(path: String, oldText: String, newText: String) throws -> String {
		let absolutePath = resolve(path)
		var content = try String(contentsOfFile: absolutePath, encoding: .utf8)

		let occurrences = content.components(separatedBy: oldText).count - 1

		guard occurrences > 0 else {
			throw CoderToolError.message("oldText not found in \(path)")
		}

		guard occurrences == 1 else {
			throw CoderToolError.message("oldText matches \(occurrences) locations in \(path). Must be unique.")
		}

		content = content.replacingOccurrences(of: oldText, with: newText)
		try content.write(toFile: absolutePath, atomically: true, encoding: .utf8)

		return "Edited \(path)"
	}

	/// List the contents of a directory.
	/// - Parameter path: Directory to list (default: working directory)
	@MCPTool
	func ls(path: String? = nil) -> String {
		let dir = resolve(path ?? ".")

		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
			return "Error: Directory not found: \(path ?? ".")"
		}

		guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
			return "Error: Cannot read directory: \(path ?? ".")"
		}

		var lines = [String]()
		for entry in entries.sorted() {
			var isDir: ObjCBool = false
			let fullPath = (dir as NSString).appendingPathComponent(entry)
			FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
			lines.append(isDir.boolValue ? "\(entry)/" : entry)
		}

		return lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n").truncatedForToolOutput()
	}

	/// Search files for a pattern. Searches recursively, respecting .gitignore.
	/// - Parameter pattern: Search pattern (regex)
	/// - Parameter path: Directory or file to search (default: working directory)
	/// - Parameter glob: Filter by file name pattern, e.g. "*.swift" or "*.ts". Do NOT use path patterns like "**/*".
	/// - Parameter ignoreCase: Case-insensitive search (default: false)
	/// - Parameter outputMode: "content" shows matching lines, "files" shows only file paths, "count" shows match counts per file. Default: "files".
	/// - Parameter limit: Maximum number of results to return. Default: 200.
	@MCPTool
	func grep(pattern: String, path: String? = nil, glob: String? = nil, ignoreCase: Bool? = nil, outputMode: String? = nil, limit: Int? = nil) -> String {
		let relativePath = relativize(path ?? ".")
		let dir = resolve(relativePath)
		let excludeDirs = Set(gitIgnore.excludeDirs)
		let excludeFiles = Set(gitIgnore.excludeFiles)
		let fm = FileManager.default
		let maxResults = limit ?? 200
		let mode = outputMode ?? "files"

		let options: NSRegularExpression.Options = ignoreCase == true ? [.caseInsensitive] : []
		guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
			return "Error: Invalid regex pattern: \(pattern)"
		}

		// If path points to a file, search just that file
		var isDirectory: ObjCBool = false
		guard fm.fileExists(atPath: dir, isDirectory: &isDirectory) else {
			return "Error: Path not found: \(relativePath)"
		}

		// Collect per-file matches: (displayPath, [(lineNumber, lineContent)])
		var fileMatches = [(String, [(Int, String)])]()
		var totalResults = 0

		if !isDirectory.boolValue {
			let matches = searchFile(atPath: dir, regex: regex)
			if !matches.isEmpty {
				fileMatches.append((relativePath, matches))
			}
		} else {
			guard let enumerator = fm.enumerator(atPath: dir) else {
				return "Error: Cannot read directory: \(relativePath)"
			}

			let globPattern = glob?.replacingOccurrences(of: "**/", with: "")

			while let entry = enumerator.nextObject() as? String {
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
				let displayPath = relativePath == "." ? entry : (relativePath as NSString).appendingPathComponent(entry)
				let matches = searchFile(atPath: filePath, regex: regex)

				if !matches.isEmpty {
					fileMatches.append((displayPath, matches))
					totalResults += mode == "content" ? matches.count : 1
					if totalResults >= maxResults { break }
				}
			}
		}

		guard !fileMatches.isEmpty else {
			return "No matches found"
		}

		var output = [String]()

		switch mode {
		case "content":
			for (filePath, matches) in fileMatches {
				for (lineNum, line) in matches {
					output.append("\(filePath):\(lineNum):\(line)")
					if output.count >= maxResults { break }
				}
				if output.count >= maxResults { break }
			}

		case "count":
			var totalCount = 0
			for (filePath, matches) in fileMatches {
				output.append("\(filePath):\(matches.count)")
				totalCount += matches.count
				if output.count >= maxResults { break }
			}
			output.append("\nFound \(totalCount) total occurrences across \(fileMatches.count) files.")

		default: // "files"
			for (filePath, _) in fileMatches {
				output.append(filePath)
				if output.count >= maxResults { break }
			}
		}

		return output.joined(separator: "\n").truncatedForToolOutput()
	}

	/// Search a single file for regex matches. Returns array of (lineNumber, lineContent).
	private func searchFile(atPath path: String, regex: NSRegularExpression) -> [(Int, String)] {
		guard let data = FileManager.default.contents(atPath: path),
			  let content = String(data: data, encoding: .utf8) else { return [] }

		var matches = [(Int, String)]()
		let lines = content.components(separatedBy: "\n")
		for (index, line) in lines.enumerated() {
			let range = NSRange(line.startIndex..., in: line)
			if regex.firstMatch(in: line, range: range) != nil {
				matches.append((index + 1, line))
			}
		}
		return matches
	}

	/// Find files matching a glob pattern.
	/// - Parameter pattern: Glob pattern, e.g. "*.swift" or "**/*.json"
	/// - Parameter path: Directory to search in (default: working directory)
	@MCPTool
	func find(pattern: String, path: String? = nil) -> String {
		let relativePath = relativize(path ?? ".")
		let dir = resolve(relativePath)
		let excludeDirs = Set(gitIgnore.excludeDirs)
		let fm = FileManager.default

		guard let enumerator = fm.enumerator(atPath: dir) else {
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
				let resultPath = relativePath == "." ? entry : (relativePath as NSString).appendingPathComponent(entry)
				results.append(resultPath)
			}
		}

		return (results.isEmpty ? "No files found" : results.joined(separator: "\n")).truncatedForToolOutput()
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
    
    internal func resolve(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return (workingDirectory as NSString).appendingPathComponent(path)
    }
}
