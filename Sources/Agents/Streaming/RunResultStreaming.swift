import Foundation
import Providers

/// Result of a streamed agent workflow run.
///
/// Returned immediately by `Runner.runStreamed()`. The agent loop runs
/// in a background `Task`, pushing events through `events`.
/// Consume with `for try await event in result.events { ... }`.
///
/// The run lives only as long as its consumer: stopping early — breaking or
/// returning out of the loop, or cancelling the task running it — cancels the
/// background run, so it starts no further turns (tools already called in the
/// current one see the cancellation).
public final class RunResultStreaming: @unchecked Sendable {
    /// Async stream of events produced by the agent loop.
    ///
    /// Each access hands out a fresh stream over the run's event buffer, and
    /// releasing that stream before it reaches the end — breaking out of the
    /// loop, dropping it unread, or cancelling the task iterating it —
    /// cancels the run. Iterate a single stream to the end; a second access
    /// doesn't resume a run the first one abandoned.
    public var events: AsyncThrowingStream<AgentStreamEvent, Error> {
        let consumer = Consumer(iterating: stream, run: task)
        return AsyncThrowingStream(unfolding: consumer.next)
    }

    /// The stream the background loop feeds through `continuation`;
    /// consumers read it through `events`.
    private let stream: AsyncThrowingStream<AgentStreamEvent, Error>

    /// The continuation used by the background loop to yield events.
    let continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation

    /// The background task running the agent loop.
    public internal(set) var task: Task<Void, Error>

    /// The last response ID from the completed stream. Use this to continue the conversation.
    /// Only valid after the events stream has been fully consumed.
    public internal(set) var lastResponseId: String?

    init(
        stream: AsyncThrowingStream<AgentStreamEvent, Error>,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        task: Task<Void, Error>
    ) {
        self.stream = stream
        self.continuation = continuation
        self.task = task
    }

    /// Cancel the background agent loop and end `events`. A consumer that
    /// just stops iterating doesn't need this; call it to stop the run from
    /// elsewhere, e.g. while the consumer is still reading.
    public func cancel() {
        task.cancel()
        continuation.finish()
    }
}

extension RunResultStreaming {
    /// One consumer's pass over the run's events, living exactly as long as
    /// the stream `events` handed out for it — so it's released when that
    /// consumer's `for try await` loop exits. (`stream` can't tell: this
    /// result, which the background loop retains, keeps it alive.) Releasing
    /// a consumer before it reached the end of the stream cancels the run.
    ///
    /// `@unchecked Sendable`: only the stream built around it calls `next()`,
    /// one call at a time, like any `AsyncThrowingStream` consumer.
    private final class Consumer: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<AgentStreamEvent, Error>.Iterator
        private let run: Task<Void, Error>
        private var reachedEnd = false

        init(iterating stream: AsyncThrowingStream<AgentStreamEvent, Error>, run: Task<Void, Error>) {
            iterator = stream.makeAsyncIterator()
            self.run = run
        }

        func next() async throws -> AgentStreamEvent? {
            do {
                let event = try await iterator.next()
                reachedEnd = event == nil
                return event
            } catch {
                // The run reports its own failure by finishing the stream
                // with the error — it's over either way.
                reachedEnd = true
                throw error
            }
        }

        deinit {
            if !reachedEnd {
                run.cancel()
            }
        }
    }
}
