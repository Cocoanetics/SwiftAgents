//
//  AnthropicStopReason.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.05.26.
//

import Foundation

/// Why the model stopped producing tokens.
public enum AnthropicStopReason: String, Codable, Sendable {
    /// Reached the end of the model's response naturally.
    case endTurn = "end_turn"

    /// Hit the `max_tokens` budget before finishing.
    case maxTokens = "max_tokens"

    /// Matched one of the request's `stop_sequences`.
    case stopSequence = "stop_sequence"

    /// Emitted a `tool_use` block — caller is expected to run the tool and continue.
    case toolUse = "tool_use"

    /// Long-running turn paused; caller can resume by re-sending the partial response.
    case pauseTurn = "pause_turn"

    /// Model refused due to policy.
    case refusal
}
