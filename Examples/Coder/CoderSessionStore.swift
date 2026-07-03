import Foundation

/// The persisted slice of an ACP session — everything needed to resume it after
/// the Coder process restarts, on `session/load`. The live MCP proxies aren't
/// here (they're reconnected from the client's `session/load` request), only the
/// durable state: the working directory, model/mode/effort selections, the
/// rolling `lastResponseId` (Coder's pointer into the provider-held conversation),
/// and a light transcript so the client can rebuild the view.
struct CoderSessionState: Codable, Sendable {
    var sessionId: String
    var cwd: String
    var model: String
    var modeId: String
    /// Reasoning-effort config option (`auto` / `low` / `medium` / `high`).
    var reasoningEffort: String
    /// The provider's last response id, so a resumed turn continues the thread.
    var lastResponseId: String?
    /// A minimal user/assistant transcript, replayed to the client on load.
    var history: [Turn]

    struct Turn: Codable, Sendable {
        var role: Role
        var text: String
        enum Role: String, Codable, Sendable { case user, assistant }
    }
}

/// One-JSON-file-per-session persistence under `~/.coder/acp-sessions/`.
///
/// Every method is best-effort: persistence must never break a live turn, so a
/// write failure is logged to stderr (never stdout — that carries JSON-RPC) and
/// swallowed, and a missing/corrupt file simply reads back as `nil`.
struct CoderSessionStore: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".coder/acp-sessions", isDirectory: true)
    }

    func load(_ sessionId: String) -> CoderSessionState? {
        guard let data = try? Data(contentsOf: url(for: sessionId)) else { return nil }
        return try? JSONDecoder().decode(CoderSessionState.self, from: data)
    }

    func save(_ state: CoderSessionState) {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: url(for: state.sessionId), options: .atomic)
        } catch {
            let message = "coder: failed to persist session \(state.sessionId): "
                + "\(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    private func url(for sessionId: String) -> URL {
        directory.appendingPathComponent(sanitized(sessionId) + ".json")
    }

    /// Session ids are `coder-<uuid>`, but keep the filename to a safe slug
    /// regardless so a hostile/odd id can't escape the sessions directory.
    private func sanitized(_ id: String) -> String {
        let mapped = id.map { char -> Character in
            char.isLetter || char.isNumber || char == "-" || char == "_" ? char : "_"
        }
        return String(mapped)
    }
}
