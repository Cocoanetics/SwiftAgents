import Foundation
import Providers
import SwiftMCP

/** Errors that can occur during agent workflow execution

 This enum defines the possible error conditions that may occur
 while running an agent workflow.
 */
public enum RunnerError: Error, LocalizedError, Equatable {
    /** Indicates the workflow has exceeded its maximum allowed number of turns

     This error is thrown when an agent workflow takes too many turns without
     reaching a final output or valid handoff, suggesting it may be stuck in a loop.
     */
    case exceededMaxTurns

    /** Indicates a streamed run requested media output on a provider that can
     only stream the chat-completion shape.

     Image/audio output isn't streamable as token deltas, and the chat
     streaming path has no event to carry the bytes. Use the non-streaming
     `Runner.run` for media output on these providers (e.g. Gemini). The OpenAI
     Responses path streams images natively and is unaffected.
     */
    case mediaOutputNotStreamable

    public var errorDescription: String? {
        switch self {
            case .exceededMaxTurns:
                return "Agent exceeded the maximum number of turns."
            case .mediaOutputNotStreamable:
                return "Streaming image/audio output isn't supported for chat-completion providers " +
                    "(e.g. Gemini). Use Runner.run instead of Runner.runStreamed."
        }
    }
}
