//
//  ConversationStateTracker.swift
//  SwiftAgents
//
//  Tracks the cross-turn pointers a stateful provider needs:
//  `previousResponseId` (chains turns on the same server-side conversation)
//  and `conversationId` (OpenAI's higher-level conversation handle, if used).
//
//  Mirrors openai-agents-python's `OpenAIServerConversationTracker`
//  (`src/agents/run_internal/oai_conversation.py:99-235`), trimmed to the
//  pieces SwiftAgents actually uses today. Specifically: we don't yet track
//  fingerprints of server-known items or unsent tool-call ids — those are
//  optimisations to avoid resending content the server already has, which
//  isn't relevant until we stop sending full input every turn.
//
//  Latest-non-nil semantics: when a turn produces a response whose id is
//  empty or matches a known sentinel (e.g. LM Studio's stateless prefix),
//  the prior id is preserved. That mirrors Python's
//  `test_hydrate_from_state_uses_latest_non_none_response_id` — a run that
//  crosses providers shouldn't blow away a valid chain id with a turn that
//  didn't produce one.

import Foundation

/// Per-run tracker for the response-id chain plus optional conversation id.
/// Internal to the Runner: callers reach the resolved final values via
/// `RunResult.lastResponseId` / `RunResult.lastConversationId`. Mirrors
/// `openai-agents-python`'s `OpenAIServerConversationTracker`.
actor ConversationStateTracker {
    private(set) var conversationId: String?
    private(set) var previousResponseId: String?

    init(conversationId: String? = nil, previousResponseId: String? = nil) {
        self.conversationId = conversationId
        self.previousResponseId = previousResponseId
    }

    /// Record the conversation id this run is attached to.
    func setConversationId(_ id: String?) {
        conversationId = id
    }

    /// Update the chain pointer from a fresh `Response`. No-op if the
    /// response carries no usable id — preserves the prior chain across
    /// turns that happened to come from a stateless provider.
    func update(from response: Response) {
        let id = response.id
        guard !id.isEmpty, Self.isChainableResponseId(id) else { return }
        previousResponseId = id
    }

    /// Force the chain pointer to a specific id (or clear it). Useful when
    /// resuming from saved state.
    func setPreviousResponseId(_ id: String?) {
        if let id, id.isEmpty || !Self.isChainableResponseId(id) {
            return
        }
        previousResponseId = id
    }

    /// Drops `previousResponseId` without touching `conversationId`. Use
    /// when handing off to a provider whose ids are incompatible with the
    /// current chain (cross-provider handoffs).
    func resetChain() {
        previousResponseId = nil
    }

    // MARK: - Helpers

    /// True if `id` looks like something a server could resolve in a
    /// future turn. Currently just a non-empty check — LM Studio and
    /// OpenAI both hand back well-formed `resp_…` ids through their
    /// OpenAI-compat Responses endpoint, so no sentinel filtering is
    /// needed.
    static func isChainableResponseId(_ id: String) -> Bool {
        !id.isEmpty
    }
}
