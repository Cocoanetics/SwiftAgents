//
//  Response.Input+ChatMessage.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 15.05.25.
//

import Foundation

extension Response.Input {
    /// Helper function to convert Response.Input to ChatMessage.
    ///
    /// Assistant tool calls (`.functionCall` elements) get folded into the
    /// preceding assistant `ChatMessage` (or open a fresh one with no text
    /// content) so the wire shape matches what Chat Completions expects:
    /// the assistant message that *initiated* a tool call must include the
    /// `tool_calls` array, with the matching `tool` result message
    /// immediately following.
    func toChatMessage() -> [ChatMessage] {
        switch self {
            case let .text(text):
                return [ChatMessage(role: .user, content: .text(text))]
            case let .array(elements):
                var messages: [ChatMessage] = []

                for element in elements {
                    switch element {
                        case let .message(message):
                            let parts = message.content.compactMap { contentElement -> ChatMessage.ContentPart? in
                                switch contentElement {
                                    case let .inputText(text), let .outputText(text):
                                        return .init(text: text)
                                    case let .inputImage(url):
                                        guard let url else { return nil }
                                        return .init(imageURL: url.absoluteString)
                                    case let .inputImageFileID(fileID):
                                        return .init(fileID: fileID)
                                }
                            }

                            let content: ChatMessage.Content? = if parts.isEmpty {
                                nil
                            } else if parts.count == 1, let firstText = parts.first?.textValue {
                                .text(firstText)
                            } else {
                                .parts(parts)
                            }

                            messages.append(ChatMessage(role: message.role, content: content, phase: message.phase))
                        case let .functionCall(call):
                            let toolCall = ToolCall(
                                id: call.callId,
                                type: "function",
                                function: FunctionCall(name: call.name, arguments: call.arguments)
                            )
                            // Fold into the preceding assistant message if
                            // present so a tool-calling turn is one ChatMessage
                            // (text + tool_calls). Otherwise open a fresh
                            // assistant message that carries only tool_calls.
                            if let last = messages.last, last.role == .assistant {
                                var merged = last
                                merged.toolCalls = (merged.toolCalls ?? []) + [toolCall]
                                messages[messages.count - 1] = merged
                            } else {
                                messages.append(ChatMessage(
                                    role: .assistant,
                                    content: nil,
                                    toolCalls: [toolCall]
                                ))
                            }
                        case let .functionCallOutput(output):
                            messages.append(ChatMessage(
                                role: .tool,
                                content: .text(output.output),
                                toolCallID: output.callId
                            ))
                        default:
                            continue
                    }
                }
                return messages
        }
    }
}
