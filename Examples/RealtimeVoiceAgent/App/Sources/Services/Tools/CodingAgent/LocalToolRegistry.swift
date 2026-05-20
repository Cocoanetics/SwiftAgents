import EventKit
import Foundation
import Providers
import SwiftMCP
import UIKit

/// `OpenAI` subclass that adds OpenClaw's `x-openclaw-session-key` header to
/// every request — the gateway uses it for server-side multi-turn continuity.
private final class OpenClawAPI: OpenAI {
    private let sessionKey: String

    init(apiKey: String, endpointURL: URL, sessionKey: String) {
        self.sessionKey = sessionKey
        super.init(apiKey: apiKey, endpointURL: endpointURL, versionPath: "v1")
    }

    override func createUrlRequest(
        httpMethod: String = "GET",
        path: String,
        body: Codable? = nil,
        queryItems: [URLQueryItem]? = nil
    ) throws -> URLRequest {
        var request = try super.createUrlRequest(
            httpMethod: httpMethod, path: path, body: body, queryItems: queryItems
        )
        request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
        return request
    }
}

/// Local tools for the realtime voice assistant.
///
/// Tool schemas are generated automatically from Swift method signatures
/// and documentation comments via SwiftMCP's `@MCPTool` macro.
@MCPServer
actor LocalToolRegistry {
    private let calendarHandler = CalendarHandler()
    private let reminderHandler = ReminderHandler()
    private let clawSessionKey = UUID().uuidString
    private let openclawEndpoint: String?
    private let openclawToken: String?

    private var onShowFile: (@MainActor @Sendable (_ title: String, _ content: String) -> Void)?

    init(openclawEndpoint: String? = nil, openclawToken: String? = nil) {
        self.openclawEndpoint = openclawEndpoint
        self.openclawToken = openclawToken
    }

    func setShowFileHandler(_ handler: @escaping @MainActor @Sendable (_ title: String, _ content: String) -> Void) {
        onShowFile = handler
    }

    // MARK: - Tools

    /// Get the current local date and time on the device.
    /// - Returns: The current date and time with timezone.
    @MCPTool
    func current_time() -> String {
        let formatter = ISO8601DateFormatter()
        return "\(formatter.string(from: Date())) (\(TimeZone.current.identifier))"
    }

    /// Read basic information about the current iPhone.
    /// - Returns: Device model, OS name, and version.
    @MCPTool
    func device_info() async -> String {
        await MainActor.run {
            let device = UIDevice.current
            return "\(device.model) running \(device.systemName) \(device.systemVersion)"
        }
    }

    /// Sleep for the given number of seconds. Useful for testing or simulating a long-running operation.
    /// - Parameter seconds: Duration to sleep, between 1 and 30.
    /// - Returns: Confirmation with actual elapsed time.
    @MCPTool
    func sleep(seconds: Int) async -> String {
        let clamped = max(1, min(seconds, 30))
        let start = Date()
        try? await Task.sleep(for: .seconds(clamped))
        let elapsed = Date().timeIntervalSince(start)
        return String(format: "Slept for %.1f seconds.", elapsed)
    }

    /// End the voice call. Call this tool when the user says goodbye,
    /// asks to hang up, or indicates they are done with the conversation.
    /// Say a brief farewell before calling this tool.
    /// - Returns: Confirmation.
    @MCPTool
    func hangup() -> String {
        "Hanging up."
    }

    /// Send a message to Clawdys. She is able to do multi-turn tasks and provide external information.
    /// The session is maintained server-side, so follow-up questions have full context.
    /// Use this when the user asks something you cannot answer yourself.
    /// - Parameter message: The question or message to send.
    /// - Parameter files: Optional list of file paths (relative to Documents) to attach. Each file's content is appended as a fenced code block.
    /// - Returns: The text response from OpenClaw.
    @MCPTool
    func messageOpenClaw(message: String, files: [String]? = nil) async -> String {
        guard let endpoint = openclawEndpoint,
              let token = openclawToken,
              let endpointURL = URL(string: endpoint) else {
            return "Error: OpenClaw endpoint or token not configured in Config/Local.xcconfig."
        }

        var content = message
        if let files, !files.isEmpty {
            for path in files {
                let absolutePath = resolveDocumentsPath(path)
                if let fileContent = try? String(contentsOfFile: absolutePath, encoding: .utf8) {
                    content += "\n\n```\(path)\n\(fileContent)\n```"
                } else {
                    content += "\n\n[Error: Could not read file \(path)]"
                }
            }
        }

        let model = UserDefaults.standard.string(forKey: "selectedModel") ?? "openclaw/default"
        let api = OpenClawAPI(apiKey: token, endpointURL: endpointURL, sessionKey: clawSessionKey)

        do {
            let response = try await api.createChatCompletion(
                model: model,
                messages: [ChatMessage(role: .user, content: .text(content))]
            )
            guard case let .text(text) = response.choices.first?.message.content else {
                return "Error: Unexpected response format."
            }
            return text
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Calendar Tools

    /// List all available calendars on the device.
    /// - Returns: A list of calendar names and their identifiers.
    @MCPTool
    func list_calendars() async throws -> String {
        let calendars = try await calendarHandler.listCalendars()
        if calendars.isEmpty { return "No calendars found." }
        return calendars.map { "- \($0.title) (id: \($0.calendarIdentifier))" }.joined(separator: "\n")
    }

    /// Fetch calendar events within a date range.
    /// - Parameter startDate: Start of the date range (defaults to now).
    /// - Parameter endDate: End of the date range (defaults to one month from start).
    /// - Parameter calendarNames: Filter by calendar names. If empty, fetches from all.
    /// - Parameter searchText: Search in event titles, locations, and notes.
    /// - Parameter includeAllDay: Whether to include all-day events (default true).
    /// - Returns: A formatted list of events.
    @MCPTool
    func fetch_events(
        startDate: Date? = nil,
        endDate: Date? = nil,
        calendarNames: [String]? = nil,
        searchText: String? = nil,
        includeAllDay: Bool = true
    ) async throws -> String {
        let events = try await calendarHandler.fetchEvents(
            startDate: startDate,
            endDate: endDate,
            calendarNames: calendarNames,
            searchText: searchText,
            includeAllDay: includeAllDay
        )
        if events.isEmpty { return "No events found." }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return events.map { event in
            var line = "- \(event.title ?? "(untitled)")"
            if let start = event.startDate { line += " | \(fmt.string(from: start))" }
            if let end = event.endDate { line += " – \(fmt.string(from: end))" }
            if let loc = event.location, !loc.isEmpty { line += " | \(loc)" }
            line += " (id: \(event.calendarItemIdentifier))"
            return line
        }.joined(separator: "\n")
    }

    /// Create a new calendar event.
    /// - Parameter title: Event title.
    /// - Parameter startDate: Start time.
    /// - Parameter endDate: End time.
    /// - Parameter calendarName: Calendar to create in (uses default if omitted).
    /// - Parameter location: Event location.
    /// - Parameter notes: Event description.
    /// - Parameter isAllDay: Whether this is an all-day event.
    /// - Parameter alarms: Alarm offsets in seconds relative to start (e.g. -600 for 10 min before).
    /// - Returns: Confirmation with the created event details.
    @MCPTool
    func create_event(
        title: String,
        startDate: Date,
        endDate: Date,
        calendarName: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        isAllDay: Bool = false,
        alarms: [Int] = []
    ) async throws -> String {
        let event = try await calendarHandler.createEvent(
            title: title,
            startDate: startDate,
            endDate: endDate,
            calendarName: calendarName,
            location: location,
            notes: notes,
            isAllDay: isAllDay,
            alarms: alarms
        )
        return "Created event '\(event.title ?? title)' (id: \(event.calendarItemIdentifier))"
    }

    /// Modify an existing calendar event.
    /// - Parameter identifier: The event identifier.
    /// - Parameter title: New title.
    /// - Parameter startDate: New start date.
    /// - Parameter endDate: New end date.
    /// - Parameter location: New location.
    /// - Parameter notes: New notes.
    /// - Returns: Confirmation.
    @MCPTool
    func modify_event(
        identifier: String,
        title: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        location: String? = nil,
        notes: String? = nil
    ) async throws -> String {
        let event = try await calendarHandler.modifyEvent(
            identifier: identifier,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location,
            notes: notes
        )
        return "Modified event '\(event.title ?? "")' (id: \(event.calendarItemIdentifier))"
    }

    /// Remove a calendar event.
    /// - Parameter identifier: The event identifier.
    /// - Returns: Confirmation.
    @MCPTool
    func remove_event(identifier: String) async throws -> String {
        try await calendarHandler.removeEvent(identifier: identifier)
        return "Event removed."
    }

    // MARK: - Reminder Tools

    /// List all available reminder lists on the device.
    /// - Returns: A list of reminder list names.
    @MCPTool
    func list_reminder_lists() async throws -> String {
        let lists = try await reminderHandler.listReminderLists()
        if lists.isEmpty { return "No reminder lists found." }
        return lists.map { "- \($0.title)" }.joined(separator: "\n")
    }

    /// Fetch reminders with optional filters.
    /// - Parameter completed: Filter by completion status. Omit to fetch all.
    /// - Parameter startDate: Start of date range.
    /// - Parameter endDate: End of date range.
    /// - Parameter listNames: Filter by reminder list names.
    /// - Parameter searchText: Search in reminder titles.
    /// - Returns: A formatted list of reminders.
    @MCPTool
    func fetch_reminders(
        completed: Bool? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        listNames: [String]? = nil,
        searchText: String? = nil
    ) async throws -> String {
        let reminders = try await reminderHandler.fetchReminders(
            completed: completed,
            startDate: startDate,
            endDate: endDate,
            listNames: listNames,
            searchText: searchText
        )
        if reminders.isEmpty { return "No reminders found." }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return reminders.map { reminder in
            let check = reminder.isCompleted ? "[x]" : "[ ]"
            var line = "\(check) \(reminder.title ?? "(untitled)")"
            if let due = reminder.dueDateComponents?.date {
                line += " | due: \(fmt.string(from: due))"
            }
            line += " (id: \(reminder.calendarItemIdentifier))"
            return line
        }.joined(separator: "\n")
    }

    /// Create a new reminder.
    /// - Parameter title: Reminder title.
    /// - Parameter dueDate: When the reminder is due.
    /// - Parameter listName: Reminder list to add to (uses default if omitted).
    /// - Parameter notes: Additional notes.
    /// - Parameter priority: Priority 1 (highest) to 9 (lowest), 0 means none.
    /// - Parameter alarms: Alarm offsets in seconds relative to due date.
    /// - Returns: Confirmation.
    @MCPTool
    func create_reminder(
        title: String,
        dueDate: Date? = nil,
        listName: String? = nil,
        notes: String? = nil,
        priority: Int = 0,
        alarms: [Int] = []
    ) async throws -> String {
        let reminder = try await reminderHandler.createReminder(
            title: title,
            dueDate: dueDate,
            listName: listName,
            notes: notes,
            priority: priority,
            alarms: alarms
        )
        return "Created reminder '\(reminder.title ?? title)' (id: \(reminder.calendarItemIdentifier))"
    }

    /// Modify an existing reminder.
    /// - Parameter identifier: The reminder identifier.
    /// - Parameter isCompleted: Mark as completed or incomplete.
    /// - Parameter title: New title.
    /// - Parameter dueDate: New due date.
    /// - Parameter notes: New notes.
    /// - Parameter priority: New priority (1-9, 0 for none).
    /// - Returns: Confirmation.
    @MCPTool
    func modify_reminder(
        identifier: String,
        isCompleted: Bool? = nil,
        title: String? = nil,
        dueDate: Date? = nil,
        notes: String? = nil,
        priority: Int? = nil
    ) async throws -> String {
        let reminder = try await reminderHandler.modifyReminder(
            identifier: identifier,
            isCompleted: isCompleted,
            title: title,
            dueDate: dueDate,
            notes: notes,
            priority: priority
        )
        return "Modified reminder '\(reminder.title ?? "")' (id: \(reminder.calendarItemIdentifier))"
    }

    /// Remove a reminder.
    /// - Parameter identifier: The reminder identifier.
    /// - Returns: Confirmation.
    @MCPTool
    func remove_reminder(identifier: String) async throws -> String {
        try await reminderHandler.removeReminder(identifier: identifier)
        return "Reminder removed."
    }

    // MARK: - File Search Tools

    /// Search file contents using a regex pattern within the app's Documents folder.
    /// - Parameter pattern: Regex pattern to search for.
    /// - Parameter path: Subdirectory to search in (relative to Documents, default: root).
    /// - Parameter glob: Filename filter glob (e.g. "*.swift", "*.json").
    /// - Parameter ignoreCase: Case-insensitive search (default: false).
    /// - Parameter outputMode: "content" shows matching lines, "files" shows only file paths, "count" shows match counts. Default: "files".
    /// - Parameter limit: Maximum number of results. Default: 200.
    @MCPTool
    func grep(pattern: String, path: String? = nil, glob: String? = nil, ignoreCase: Bool? = nil, outputMode: String? = nil, limit: Int? = nil) -> String {
        let dir = resolveDocumentsPath(path ?? ".")
        let gitIgnore = GitIgnore(workingDirectory: Self.documentsDirectory)
        let excludeDirs = Set(gitIgnore.excludeDirs)
        let excludeFiles = Set(gitIgnore.excludeFiles)
        let fm = FileManager.default
        let maxResults = limit ?? 200
        let mode = outputMode ?? "files"

        let options: NSRegularExpression.Options = ignoreCase == true ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return "Error: Invalid regex pattern: \(pattern)"
        }

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDirectory) else {
            return "Error: Path not found: \(path ?? ".")"
        }

        var fileMatches = [(String, [(Int, String)])]()
        var totalResults = 0

        if !isDirectory.boolValue {
            let matches = searchFile(atPath: dir, regex: regex)
            if !matches.isEmpty {
                fileMatches.append((path ?? dir, matches))
            }
        } else {
            guard let enumerator = fm.enumerator(atPath: dir) else {
                return "Error: Cannot read directory: \(path ?? ".")"
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
                if excludeFiles.contains(where: { fnmatch($0, fileName, 0) == 0 }) { continue }
                if let globPattern, fnmatch(globPattern, fileName, 0) != 0 { continue }

                let filePath = (dir as NSString).appendingPathComponent(entry)
                let matches = searchFile(atPath: filePath, regex: regex)
                if !matches.isEmpty {
                    fileMatches.append((entry, matches))
                    totalResults += mode == "content" ? matches.count : 1
                    if totalResults >= maxResults { break }
                }
            }
        }

        guard !fileMatches.isEmpty else { return "No matches found" }

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
        default:
            for (filePath, _) in fileMatches {
                output.append(filePath)
                if output.count >= maxResults { break }
            }
        }
        return output.joined(separator: "\n").truncatedForToolOutput()
    }

    /// Find files matching a glob pattern in the app's Documents folder.
    /// - Parameter pattern: Glob pattern, e.g. "*.swift" or "**/*.json".
    /// - Parameter path: Subdirectory to search in (relative to Documents, default: root).
    @MCPTool
    func find(pattern: String, path: String? = nil) -> String {
        let dir = resolveDocumentsPath(path ?? ".")
        let gitIgnore = GitIgnore(workingDirectory: Self.documentsDirectory)
        let excludeDirs = Set(gitIgnore.excludeDirs)
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(atPath: dir) else {
            return "Error: Cannot read directory: \(path ?? ".")"
        }

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
                results.append(entry)
            }
        }
        return (results.isEmpty ? "No files found" : results.joined(separator: "\n")).truncatedForToolOutput()
    }

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

    // MARK: - Patch Tool

    /// Apply a V4A patch to create, update, or delete a file in the app's Documents folder.
    ///
    /// ## Patch Format
    ///
    /// A patch contains one or more file sections, terminated by `*** End Patch`.
    ///
    /// **Add File** — every content line must be prefixed with `+`:
    /// ```
    /// *** Add File: path/to/file.md
    /// +first line of content
    /// +second line of content
    /// *** End Patch
    /// ```
    ///
    /// **Update File** — uses context lines (` ` prefix), deletions (`-`), and insertions (`+`):
    /// ```
    /// *** Update File: path/to/file.md
    ///  context line
    /// -old line
    /// +new line
    ///  context line
    /// *** End Patch
    /// ```
    ///
    /// **Delete File:**
    /// ```
    /// *** Delete File: path/to/file.md
    /// *** End Patch
    /// ```
    ///
    /// - Parameter patch: The full V4A patch string.
    /// - Returns: A summary of what was applied.
    @MCPTool
    func apply_patch(patch: String) throws -> String {
        let lines = patch.components(separatedBy: "\n")
        var results = [String]()
        var i = 0

        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix("*** Add File: ") {
                let path = String(line.dropFirst("*** Add File: ".count))
                let absolutePath = resolveDocumentsPath(path)
                let diffStart = i + 1
                let diffEnd = findSectionEnd(lines, from: diffStart)
                let diff = lines[diffStart..<diffEnd].joined(separator: "\n")
                let content = try applyDiff(input: "", diff: diff, mode: .create)
                let dir = (absolutePath as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try content.write(toFile: absolutePath, atomically: true, encoding: .utf8)
                results.append("Created \(path)")
                i = diffEnd

            } else if line.hasPrefix("*** Update File: ") {
                let path = String(line.dropFirst("*** Update File: ".count))
                let absolutePath = resolveDocumentsPath(path)
                let original = try String(contentsOfFile: absolutePath, encoding: .utf8)
                let diffStart = i + 1
                let diffEnd = findSectionEnd(lines, from: diffStart)
                let diff = lines[diffStart..<diffEnd].joined(separator: "\n")
                let patched = try applyDiff(input: original, diff: diff)
                try patched.write(toFile: absolutePath, atomically: true, encoding: .utf8)
                results.append("Updated \(path)")
                i = diffEnd

            } else if line.hasPrefix("*** Delete File: ") {
                let path = String(line.dropFirst("*** Delete File: ".count))
                let absolutePath = resolveDocumentsPath(path)
                try FileManager.default.removeItem(atPath: absolutePath)
                results.append("Deleted \(path)")
                i += 1

            } else {
                i += 1
            }
        }

        return results.isEmpty ? "No operations found in patch." : results.joined(separator: "\n")
    }

    private func findSectionEnd(_ lines: [String], from start: Int) -> Int {
        let terminators = ["*** End Patch", "*** Update File:", "*** Delete File:", "*** Add File:"]
        for i in start..<lines.count {
            if terminators.contains(where: { lines[i].hasPrefix($0) }) {
                return lines[i].hasPrefix("*** End Patch") ? i + 1 : i
            }
        }
        return lines.count
    }

    // MARK: - File Tools (sandboxed to Documents)

    /// List the contents of a directory in the app's Documents folder.
    /// - Parameter path: Directory to list (default: root of Documents)
    /// - Returns: Directory listing with trailing / for subdirectories.
    @MCPTool
    func ls(path: String? = nil) -> String {
        let dir = resolveDocumentsPath(path ?? ".")
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "Error: Directory not found: \(path ?? ".")"
        }

        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
            return "Error: Cannot read directory: \(path ?? ".")"
        }

        var lines = [String]()
        for entry in entries.sorted() {
            var isDir: ObjCBool = false
            let fullPath = (dir as NSString).appendingPathComponent(entry)
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            lines.append(isDir.boolValue ? "\(entry)/" : entry)
        }

        return lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n")
    }

    /// Read the contents of a file in the app's Documents folder. Use offset/limit for large files.
    /// - Parameter path: Path to the file (relative to Documents)
    /// - Parameter offset: Line number to start reading from (1-indexed, optional)
    /// - Parameter limit: Maximum number of lines to read (optional)
    /// - Returns: The file contents with line numbers.
    @MCPTool
    func read(path: String, offset: Int? = nil, limit: Int? = nil) throws -> String {
        let absolutePath = resolveDocumentsPath(path)
        let content = try String(contentsOfFile: absolutePath, encoding: .utf8)
        let allLines = content.components(separatedBy: "\n")

        let startLine = max(0, (offset ?? 1) - 1)

        guard startLine < allLines.count else {
            throw ToolError.message("Offset \(offset ?? 1) is beyond end of file (\(allLines.count) lines)")
        }

        let selected: [String]
        if let limit {
            let endLine = min(startLine + limit, allLines.count)
            selected = Array(allLines[startLine..<endLine])
        } else {
            selected = Array(allLines[startLine...])
        }

        let output = selected.joined(separator: "\n")
        let remaining = allLines.count - (startLine + selected.count)
        if remaining > 0 {
            let nextOffset = startLine + selected.count + 1
            return output + "\n\n[\(remaining) more lines. Use offset=\(nextOffset) to continue.]"
        }

        return output
    }

    /// Show a file from the Documents folder to the user as rendered Markdown in a sheet.
    /// - Parameter path: Path to the file (relative to Documents)
    /// - Returns: Confirmation that the file is being displayed.
    @MCPTool
    func show(path: String) throws -> String {
        let absolutePath = resolveDocumentsPath(path)
        let content = try String(contentsOfFile: absolutePath, encoding: .utf8)
        let title = (path as NSString).lastPathComponent
        if let onShowFile {
            Task { @MainActor in
                onShowFile(title, content)
            }
        }
        return "Showing \(title)"
    }

    /// The app's Documents directory URL.
    var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    // MARK: - Path Sandboxing

    private static let documentsDirectory: String = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return url.path
    }()

    /// Resolve a path relative to the app's Documents directory.
    /// Absolute paths are rejected to prevent escaping the sandbox.
    private func resolveDocumentsPath(_ path: String) -> String {
        let clean = path.replacingOccurrences(of: "..", with: "")
        if clean == "." { return Self.documentsDirectory }
        let resolved = (Self.documentsDirectory as NSString).appendingPathComponent(clean)
        if FileManager.default.fileExists(atPath: resolved) { return resolved }
        return caseInsensitiveMatch(for: resolved) ?? resolved
    }

    private func caseInsensitiveMatch(for path: String) -> String? {
        let fm = FileManager.default
        let components = (path as NSString).pathComponents
        let baseComponents = (Self.documentsDirectory as NSString).pathComponents
        guard components.count > baseComponents.count else { return nil }

        var current = baseComponents.joined(separator: "/")
        for component in components[baseComponents.count...] {
            guard let contents = try? fm.contentsOfDirectory(atPath: current) else { return nil }
            guard let match = contents.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame }) else { return nil }
            current = (current as NSString).appendingPathComponent(match)
        }
        return current
    }

    enum ToolError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let msg): return msg }
        }
    }
}
