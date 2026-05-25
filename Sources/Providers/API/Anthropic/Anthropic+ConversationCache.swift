//
//  Anthropic+ConversationCache.swift
//  SwiftAgents
//
//  Anthropic's Messages API is stateless — every request must include the
//  full conversation history. The Agents SDK Runner, however, is designed
//  around OpenAI's stateful Responses API (only the latest tool results are
//  passed; prior turns are referenced by `previousResponseId`).
//
//  Bridging the two: this cache stores the full Anthropic-shaped message
//  list that led to a given response, keyed by that response's id. When the
//  Runner re-enters createResponse with a `previousResponseId`, we look up
//  the prior history and prepend it before sending the new request.

import Foundation

/// Thread-safe conversation cache keyed by Anthropic message id.
public actor AnthropicConversationCache {
    /// Hard cap on the number of conversations kept in memory at once.
    /// Anthropic conversation IDs are short-lived (per-process); the cap is
    /// here just so a long-running daemon can't leak memory if it never
    /// drops references.
    public let maxEntries: Int

    /// Insertion order so we can evict the oldest entries when we exceed
    /// `maxEntries`. Using a simple array because Swift doesn't have an
    /// ordered set in stdlib and the entry count is tiny.
    private var order: [String] = []
    private var conversations: [String: [AnthropicMessage]] = [:]

    public init(maxEntries: Int = 256) {
        self.maxEntries = maxEntries
    }

    public func messages(forResponseId id: String) -> [AnthropicMessage]? {
        conversations[id]
    }

    public func store(messages: [AnthropicMessage], forResponseId id: String) {
        if conversations[id] == nil {
            order.append(id)
        }
        conversations[id] = messages

        while order.count > maxEntries {
            let oldest = order.removeFirst()
            conversations.removeValue(forKey: oldest)
        }
    }
}

extension Anthropic {
    /// Convenience: append the latest assistant turn to `priorMessages` and
    /// store the result under `responseId`. Future calls with the same id
    /// pick up exactly this conversation.
    func cacheConversation(
        priorMessages: [AnthropicMessage],
        assistantContent: [AnthropicContentBlock],
        responseId: String
    ) async {
        let assistant = AnthropicMessage(role: .assistant, content: .blocks(assistantContent))
        let fullHistory = priorMessages + [assistant]
        await conversationCache.store(messages: fullHistory, forResponseId: responseId)
    }
}
