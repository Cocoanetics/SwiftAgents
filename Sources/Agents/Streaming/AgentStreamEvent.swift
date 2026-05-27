import Foundation
import Providers

/// Events emitted during a streamed agent run.
///
/// Modeled after the OpenAI Agents Python SDK's three-tier event model:
/// raw LLM events, semantic run items, and agent lifecycle events.
public enum AgentStreamEvent: Sendable {
    /// Raw LLM streaming event (text deltas, function argument deltas, etc.)
    case rawResponseEvent(ResponsesStreamEvent)

    /// Semantic event for agent state changes (tool called, tool output, message completed, etc.)
    case runItemEvent(name: RunItemEventName, item: RunItem)

    /// The current agent changed due to a handoff.
    case agentUpdated(name: String)
}

/// Names for semantic run item events.
public enum RunItemEventName: String, Sendable {
    case messageOutputCreated
    case toolCalled
    case toolOutput
    case handoffRequested
}

/// A semantic item produced during a streamed run.
public enum RunItem: Sendable {
    case message(String)
    case toolCall(name: String, arguments: String, callId: String)
    case toolOutput(callId: String, output: String)
}
