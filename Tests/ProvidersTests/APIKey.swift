import Foundation

// SwiftDotenv only builds on Apple platforms. On Linux / Windows /
// Android the tests still read keys from the environment directly via
// `ProcessInfo.processInfo.environment[…]`; .env loading is just a
// developer convenience that we skip out on those platforms.
#if canImport(SwiftDotenv)
import SwiftDotenv
#endif

enum APIKey {
    private static let envLoaded: Void = {
        #if canImport(SwiftDotenv)
        guard let envURL = findEnvFile() else { return }
        try? Dotenv.configure(atPath: envURL.path)
        #endif
    }()

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

    private static func loadEnvIfNeeded() {
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
