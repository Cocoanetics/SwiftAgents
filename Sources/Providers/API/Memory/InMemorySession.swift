//
//  InMemorySession.swift
//  SwiftAgents
//
//  Process-local Session backed by an actor-protected array. Items vanish
//  when the actor is released; for persistence across process restarts, use
//  a file or database-backed Session implementation.

import Foundation

/// Process-local Session implementation. Backed by an actor so concurrent
/// reads/writes from multiple turns / multiple agents serialise safely.
public actor InMemorySession: Session {
    public let sessionId: String
    private var items: [Response.Input.Element] = []

    public init(sessionId: String = UUID().uuidString) {
        self.sessionId = sessionId
    }

    /// Seed the session with pre-existing items (e.g. when reconstructing
    /// from disk on startup).
    public init(sessionId: String = UUID().uuidString, items: [Response.Input.Element]) {
        self.sessionId = sessionId
        self.items = items
    }

    public func getItems(limit: Int?) async -> [Response.Input.Element] {
        guard let limit, limit >= 0 else { return items }
        if limit >= items.count { return items }
        return Array(items.suffix(limit))
    }

    public func addItems(_ newItems: [Response.Input.Element]) async {
        items.append(contentsOf: newItems)
    }

    public func popItem() async -> Response.Input.Element? {
        items.popLast()
    }

    public func clearSession() async {
        items.removeAll()
    }
}
