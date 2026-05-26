import Foundation

/// Result of a completed agent workflow run.
///
/// Mirrors `openai-agents-python`'s `RunResult`: alongside the final output
/// it carries the resolved conversation pointers so the caller can resume
/// the chain in a follow-up `Runner.run` call. The pointers always reflect
/// whatever state the run produced, regardless of which path it took:
///   - For stateful providers (OpenAI Responses, LM Studio native chat),
///     `lastResponseId` is the most recent server-issued id.
///   - When the caller used `conversationId`, the same value comes back on
///     `lastConversationId`.
///   - Stateless providers (Anthropic, Ollama) leave both as nil.
public struct RunResult<T: Sendable>: Sendable {
    /// The final output value produced by the agent workflow.
    public var finalOutput: T

    /// Optional reasoning summary returned by reasoning-capable models.
    public var finalReasoning: String?

    /// Most recent response id worth chaining off. Pass back as
    /// `previousResponseId` on the next `Runner.run` call to resume.
    public var lastResponseId: String?

    /// OpenAI Conversations API handle the run was attached to (if any).
    /// Round-trip via `conversationId` on the next `Runner.run` call.
    public var lastConversationId: String?

    /// Whether the run's chain pointer was tracked automatically (i.e. the
    /// caller didn't supply `previousResponseId` but the runner stored ids
    /// across turns anyway). Round-tripped so the caller can preserve the
    /// flag on resume.
    public var autoPreviousResponseId: Bool

    public init(
        finalOutput: T,
        finalReasoning: String? = nil,
        lastResponseId: String? = nil,
        lastConversationId: String? = nil,
        autoPreviousResponseId: Bool = false
    ) {
        self.finalOutput = finalOutput
        self.finalReasoning = finalReasoning
        self.lastResponseId = lastResponseId
        self.lastConversationId = lastConversationId
        self.autoPreviousResponseId = autoPreviousResponseId
    }
}
