//
//  OutputItem+InputElement.swift
//  SwiftAgents
//
//  Lifts assistant-side `OutputItem`s into the `Response.Input.Element`
//  shape so they can be appended to a `Session` and replayed back to a
//  stateless model on the next turn. Mirrors openai-agents-python's
//  `ItemHelpers.input_to_new_input_list` / `_response_output_to_input`
//  conversions.
//
//  Items that don't have a meaningful input-side equivalent (mcp call
//  results, apply-patch calls — those go through their own dedicated
//  output elements) return nil and the runner is expected to skip them.

import Foundation
import JSONFoundation

public extension OutputItem {
    /// Best-effort conversion to a `Response.Input.Element` suitable for
    /// storing in a `Session`. Returns nil for output items that have no
    /// input-side equivalent the runner would want to replay.
    ///
    /// - Parameter preservingReasoning: replay `reasoning` items too (as raw
    ///   input items, encrypted content included). Off by default — reasoning
    ///   is server-side state on stateful backends — but required for
    ///   stateless backends (`store: false`), where the Responses API rejects
    ///   a resent `function_call` whose preceding reasoning item is missing.
    func toInputElement(preservingReasoning: Bool = false) -> Response.Input.Element? {
        switch self {
            case let .message(message):
                // Assistant text must be `output_text` on the wire when
                // replayed as input (OpenAI rejects `input_text` on
                // assistant messages); user/system/tool messages use
                // `input_text`.
                let useOutputText = message.role == .assistant
                let pieces: [Response.Input.ContentElement] = message.content.compactMap { piece in
                    if case let .outputText(text) = piece {
                        return useOutputText ? .outputText(text.text) : .inputText(text.text)
                    }
                    return nil
                }
                return .message(.init(
                    role: message.role,
                    content: pieces,
                    phase: message.phase
                ))
            case let .functionCall(call):
                return .functionCall(call)
            case let .fileSearch(file):
                return .fileSearch(file)
            case let .webSearch(web):
                return .webSearch(web)
            case let .imageGenerationCall(call):
                // Replayed as a bare `{ type, id }` reference so a later turn
                // can edit or refer to the image without resending the bytes.
                return .imageGenerationCall(call)
            case let .computer(comp):
                return .computerCall(comp)
            case let .reasoning(reasoning):
                // Reasoning summaries are server-side state on the original
                // turn; they aren't replayed as input on the next turn —
                // unless the caller opts in (stateless backends resend them
                // verbatim, carrying the encrypted chain of thought).
                guard preservingReasoning else { return nil }

                // Raw wire item so the opaque `encrypted_content` survives
                // the round-trip byte-for-byte (keys pre-snake_cased — the
                // request encoder's key strategy leaves them untouched).
                var object: [String: JSONValue] = [
                    "type": .string("reasoning"),
                    "id": .string(reasoning.id),
                    "summary": .array(reasoning.summary.map { item in
                        .object(["type": .string(item.type), "text": .string(item.text)])
                    })
                ]
                if let encrypted = reasoning.encryptedContent {
                    object["encrypted_content"] = .string(encrypted)
                }
                return .raw(.object(object))
            case .mcpListTools, .mcpApprovalRequest, .mcpCall:
                // MCP outputs flow through dedicated input elements
                // (mcpApprovalResponse). Don't double-store them here.
                return nil
            case .applyPatchCall:
                // The matching `applyPatchCallOutput` element is built by
                // the runner once the patch executes; this output item
                // itself isn't replayed.
                return nil
        }
    }
}

public extension Response.Input.Element {
    /// Wraps a free-form user string in the session-storable shape.
    static func userMessage(_ text: String) -> Response.Input.Element {
        .message(.init(role: .user, text: text))
    }
}
