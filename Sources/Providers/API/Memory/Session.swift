//
//  Session.swift
//  SwiftAgents
//
//  Provider-agnostic conversation storage. A `Session` holds the canonical
//  list of `Response.Input.Element`s that make up a conversation — user
//  messages, assistant outputs (lifted from `OutputItem`), function calls,
//  function call outputs, etc. The Runner uses a session to source the
//  history it sends to stateless providers (full list every turn) and to
//  preserve assistant outputs across turns even when a stateful provider
//  keeps its own server-side copy.
//
//  Direct port of openai-agents-python's `Session` protocol
//  (`src/agents/memory/session.py:14-151`). Differences from the Python
//  shape:
//    - Methods are `async throws` rather than just `async` so persistent
//      backends (SQLite, file) can surface IO errors.
//    - We use `Sendable` rather than ABC so concrete implementations can be
//      actors, structs, or classes as appropriate.
//    - `getItems(limit:)` returns the most recent N items (matching Python's
//      semantics — the limit slices from the tail).

import Foundation

/// A persistent (or in-memory) conversation log keyed by a session id. The
/// Runner appends user input, assistant outputs, function call results, etc.
/// to the session as the run progresses; subsequent runs against the same
/// session pick up where the previous one left off.
public protocol Session: Sendable {
    /// Stable identifier for this conversation. Useful for storage backends
    /// that key on it (file path, SQLite row, etc.). Async because some
    /// backends (e.g. `OpenAIConversationsSession`) lazy-create the id on
    /// first access by calling out to a remote service.
    var sessionId: String { get async }

    /// Returns the stored items in chronological order. When `limit` is set,
    /// returns the most recent `limit` items.
    func getItems(limit: Int?) async throws -> [Response.Input.Element]

    /// Appends items to the end of the session.
    func addItems(_ items: [Response.Input.Element]) async throws

    /// Removes and returns the most recently added item, or `nil` if the
    /// session is empty. Useful for undo / retry flows.
    func popItem() async throws -> Response.Input.Element?

    /// Removes all items from the session.
    func clearSession() async throws
}

public extension Session {
    /// Convenience: fetch the entire history.
    func getItems() async throws -> [Response.Input.Element] {
        try await getItems(limit: nil)
    }
}
