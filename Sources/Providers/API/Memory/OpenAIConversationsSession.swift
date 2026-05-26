//
//  OpenAIConversationsSession.swift
//  SwiftAgents
//
//  Session backend whose storage is an OpenAI Conversations API
//  conversation. From the Runner's perspective it's just a Session —
//  `getItems` lists items from the server, `addItems` posts items to the
//  server, `clearSession` deletes the conversation. The conversation id
//  is exposed via `sessionId` and (where present) lazily created on first
//  call.
//
//  Direct port of `openai-agents-python`'s `OpenAIConversationsSession`
//  (`src/agents/memory/openai_conversations_session.py`).
//
//  Known limitation: `getItems` currently lifts message items (user /
//  assistant text) only. Function-call items returned by the Conversations
//  API don't yet round-trip — the wire `ConversationItem` model needs the
//  function_call name/arguments/call_id fields to do that fully. Tracked
//  as a follow-up; for now those items are skipped in `getItems` but still
//  stored server-side via `addItems`.

import Foundation

/// Session backed by an OpenAI Conversations API conversation. Storage
/// lives on OpenAI's servers; the local actor only holds the conversation
/// id (or `nil` until the first call lazy-creates one).
public actor OpenAIConversationsSession: Session {
    private let openAI: OpenAI
    private var conversationId: String?

    public init(conversationId: String? = nil, openAI: OpenAI? = nil) {
        self.conversationId = conversationId
        self.openAI = openAI ?? OpenAI()
    }

    public var sessionId: String {
        get async {
            // Best-effort accessor. The protocol's `sessionId` is
            // non-throwing async, so we can't surface creation errors here;
            // they propagate cleanly through `getItems`/`addItems` instead.
            // Returns the cached id, or "" if lazy creation hasn't happened
            // yet (or failed) — mirrors Python's behaviour of raising on
            // uninitialised access, just degraded to a sentinel value.
            (try? await ensureConversationId()) ?? ""
        }
    }

    public func getItems(limit: Int?) async throws -> [Response.Input.Element] {
        let conversationId = try await ensureConversationId()

        // When the caller asks for "everything" (nil), page through until
        // `has_more` goes false. The API caps each page at 100 items, so a
        // long conversation needs multiple round trips — capping silently
        // at 100 was hiding context from the runner on resumes. When the
        // caller passes an explicit limit we honour it as the single-page
        // size the way Python does.
        if let limit {
            let pageLimit = max(1, min(100, limit))
            let list = try await openAI.listConversationItems(
                conversationId: conversationId,
                limit: pageLimit,
                order: .ascending
            )
            return list.data.compactMap(Self.toInputElement)
        }

        var collected: [ConversationItem] = []
        var after: String?
        repeat {
            let page = try await openAI.listConversationItems(
                conversationId: conversationId,
                limit: 100,
                order: .ascending,
                after: after
            )
            collected.append(contentsOf: page.data)
            guard page.hasMore, let lastId = page.lastId else { break }
            after = lastId
        } while true
        return collected.compactMap(Self.toInputElement)
    }

    public func addItems(_ items: [Response.Input.Element]) async throws {
        guard !items.isEmpty else { return }
        let conversationId = try await ensureConversationId()
        _ = try await openAI.createConversationItems(
            conversationId: conversationId,
            items: items
        )
    }

    public func popItem() async throws -> Response.Input.Element? {
        let conversationId = try await ensureConversationId()
        let list = try await openAI.listConversationItems(
            conversationId: conversationId,
            limit: 1,
            order: .descending
        )
        guard let item = list.data.first else { return nil }
        _ = try await openAI.deleteConversationItem(
            conversationId: conversationId,
            itemId: item.id
        )
        return Self.toInputElement(item)
    }

    public func clearSession() async throws {
        guard let id = conversationId else { return }
        _ = try await openAI.deleteConversation(id: id)
        conversationId = nil
    }

    // MARK: - Helpers

    /// Returns the underlying OpenAI conversation id, lazily creating an
    /// empty conversation if the session hasn't been used yet. Throws
    /// directly if creation fails — callers see the real auth/network
    /// error instead of a fabricated id that would later 404 against the
    /// API and obscure the root cause.
    private func ensureConversationId() async throws -> String {
        if let conversationId { return conversationId }
        let created = try await openAI.createConversation()
        conversationId = created.id
        return created.id
    }

    /// Best-effort conversion of a wire `ConversationItem` into a
    /// `Response.Input.Element`. Currently handles message items only;
    /// returns nil for items the local `ConversationItem` model can't
    /// fully reconstruct (function_call lacks name/arguments/call_id at
    /// this level of the wire schema).
    static func toInputElement(_ item: ConversationItem) -> Response.Input.Element? {
        guard item.type == "message",
              let roleRaw = item.role,
              let role = Role(rawValue: roleRaw) else {
            return nil
        }
        // Preserve the wire content type when round-tripping: assistant
        // messages must come back as `output_text` (the API rejects
        // `input_text` for assistant role), user/system as `input_text`.
        let parts: [Response.Input.ContentElement] = (item.content ?? []).compactMap { content in
            guard let text = content.text else { return nil }
            switch content.type {
                case "output_text": return .outputText(text)
                case "input_text": return .inputText(text)
                default: return nil
            }
        }
        return .message(.init(role: role, content: parts))
    }
}
