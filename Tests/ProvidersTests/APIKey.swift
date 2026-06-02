import Foundation
import SwiftCross

enum APIKey {
    private static let envLoaded: Void = {
        guard let envURL = findEnvFile() else { return }
        loadDotenv(at: envURL)
    }()

    /// Tolerant `.env` loader. Reads the file line by line, ignores
    /// blank lines and `#` comments, and *skips* present-but-empty
    /// pairs (`ANTHROPIC_API_KEY=`) rather than throwing on them. We
    /// rolled our own loader because SwiftDotenv's `configure` throws
    /// `malformedKeyValuePair` on the first empty value and bails out
    /// of the rest of the file — which silently strands every key
    /// declared below the first empty one (e.g. `LMSTUDIO_URL` after
    /// an empty `GEMINI_API_KEY=`). Uses `SwiftCross.Environment.set`
    /// (cross-platform `setenv`) so the values land in
    /// `ProcessInfo.processInfo.environment` just like the SwiftDotenv path did.
    private static func loadDotenv(at url: URL) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            Environment.set(key, value)
        }
    }

    private static func findEnvFile() -> URL? {
        let candidates = [".env.development", ".env"]
        var current = URL(fileURLWithPath: #file).deletingLastPathComponent()
        let fileManager = FileManager.default
        while true {
            for name in candidates {
                let candidate = current.appendingPathComponent(name)
                if fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    /// Triggers SwiftDotenv to load the nearest `.env` (or
    /// `.env.development`) on first call. Safe to call repeatedly — the
    /// underlying `static let envLoaded` bootstrap guarantees the loader
    /// only runs once per process. Exposed `internal` so other helpers
    /// in this test target (notably `TestClients` for local-LLM gates
    /// like `hasLMStudio`) can opt into the same .env load before
    /// consulting `ProcessInfo.processInfo.environment`.
    static func loadEnvIfNeeded() {
        _ = envLoaded
    }

    static var openAI: String? {
        loadEnvIfNeeded()
        return nonEmpty(ProcessInfo.processInfo.environment["OPENAI_API_KEY"])
    }

    static var gemini: String? {
        loadEnvIfNeeded()
        return nonEmpty(ProcessInfo.processInfo.environment["GEMINI_API_KEY"])
    }

    static var anthropic: String? {
        loadEnvIfNeeded()
        return nonEmpty(ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"])
    }

    /// `.env` files commonly leave keys present-but-empty (`ANTHROPIC_API_KEY=`).
    /// Treat those the same as unset so the `enabled(if:)` gates correctly
    /// skip rather than running with a blank key and hitting a server-side
    /// 401.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static var hasOpenAI: Bool {
        openAI != nil
    }

    static var hasGemini: Bool {
        gemini != nil
    }

    static var hasAnthropic: Bool {
        anthropic != nil
    }
}
