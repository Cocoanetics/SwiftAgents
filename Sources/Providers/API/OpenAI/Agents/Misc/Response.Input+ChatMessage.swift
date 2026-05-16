//
//  Response.Input+ChatMessage.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 15.05.25.
//

import Foundation

extension Response.Input {
    /// Helper function to convert Response.Input to ChatMessage
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
                                    case let .inputText(text):
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
