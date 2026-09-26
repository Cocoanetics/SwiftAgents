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
    /// Events produced by the agent loop, in order.
    ///
    /// The run is tied to the iteration, not to this value: an iteration that
    /// ends before the run does — breaking or returning out of the loop, or its
    /// task being cancelled — cancels the run, even if `events` itself is kept
    /// around. Iterate once to the end; a second iteration doesn't resume a run
    /// the first one abandoned.
    public var events: Events {
        Events(stream: stream, run: task)
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
    /// The events of a streamed run — see `RunResultStreaming.events`.
    public struct Events: AsyncSequence, Sendable {
        public typealias Element = AgentStreamEvent

        fileprivate let stream: AsyncThrowingStream<AgentStreamEvent, Error>
        fileprivate let run: Task<Void, Error>

        public func makeAsyncIterator() -> Iterator {
            Iterator(base: stream.makeAsyncIterator(), lease: IterationLease(run: run))
        }

        public struct Iterator: AsyncIteratorProtocol {
            private var base: AsyncThrowingStream<AgentStreamEvent, Error>.Iterator
            private let lease: IterationLease

            fileprivate init(
                base: AsyncThrowingStream<AgentStreamEvent, Error>.Iterator,
                lease: IterationLease
            ) {
                self.base = base
                self.lease = lease
            }

            public mutating func next() async throws -> AgentStreamEvent? {
                do {
                    return try await lease.passing(base.next())
                } catch {
                    throw lease.ending(with: error)
                }
            }

            /// Reads in the caller's isolation, like `AsyncThrowingStream`'s
            /// own iterator, instead of hopping off it for every event.
            @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
            public mutating func next(isolation actor: isolated (any Actor)?) async throws -> AgentStreamEvent? {
                do {
                    return try await lease.passing(base.next(isolation: actor))
                } catch {
                    throw lease.ending(with: error)
                }
            }
        }
    }

    /// Ties the run to one iteration of `events`. Released together with the
    /// iterator — when its loop exits, however it exits — it cancels the run
    /// unless the iteration reached the end of the stream. (The iterator's
    /// lifetime is the signal: the `Events` value, or the stream behind it,
    /// may outlive an abandoned loop.)
    fileprivate final class IterationLease {
        private let run: Task<Void, Error>
        private var reachedEnd = false

        init(run: Task<Void, Error>) {
            self.run = run
        }

        /// Passes `event` on, noting the end of the stream (`nil`).
        func passing(_ event: AgentStreamEvent?) -> AgentStreamEvent? {
            reachedEnd = event == nil
            return event
        }

        /// Passes `error` on: the run reports its own failure by finishing
        /// the stream with it — it's over either way.
        func ending(with error: any Error) -> any Error {
            reachedEnd = true
            return error
        }

        deinit {
            if !reachedEnd {
                run.cancel()
            }
        }
    }
}
