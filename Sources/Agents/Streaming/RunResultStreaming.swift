import Foundation
import Providers

/// Result of a streamed agent workflow run.
///
/// Returned immediately by `Runner.runStreamed()`. The agent loop runs
/// in a background `Task`, pushing events through `events`.
/// Consume with `for try await event in result.events { ... }`.
public final class RunResultStreaming: @unchecked Sendable {
    /// Async stream of events produced by the agent loop.
    public let events: AsyncThrowingStream<AgentStreamEvent, Error>

    /// The continuation used by the background loop to yield events.
    let continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation

    /// The background task running the agent loop.
    public internal(set) var task: Task<Void, Error>

    /// The last response ID from the completed stream. Use this to continue the conversation.
    /// Only valid after the events stream has been fully consumed.
    public internal(set) var lastResponseId: String?

    init(
        events: AsyncThrowingStream<AgentStreamEvent, Error>,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        task: Task<Void, Error>
    ) {
        self.events = events
        self.continuation = continuation
        self.task = task
    }

    /// Cancel the background agent loop.
    public func cancel() {
        task.cancel()
        continuation.finish()
    }
}
