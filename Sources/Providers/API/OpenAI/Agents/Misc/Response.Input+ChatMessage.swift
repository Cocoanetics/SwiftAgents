//
//  Response.Input+ChatMessage.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 15.05.25.
//


import Foundation

extension Response.Input
{
	// Helper function to convert Response.Input to ChatMessage
	func toChatMessage() -> [ChatMessage] {
		switch self {
			case .text(let text):
				return [ChatMessage(role: .user, content: .text(text))]
			case .array(let elements):
				var messages: [ChatMessage] = []
				
				for element in elements {
					switch element {
						case .message(let message):
							let parts = message.content.compactMap { contentElement -> ChatMessage.ContentPart? in
								switch contentElement {
									case .inputText(let text):
										return .init(text: text)
									case .inputImage(let url):
										guard let url else { return nil }
										return .init(imageURL: url.absoluteString)
									case .inputImageFileID(let fileID):
										return .init(fileID: fileID)
								}
							}

							let content: ChatMessage.Content?
							if parts.isEmpty {
								content = nil
							} else if parts.count == 1, let firstText = parts.first?.textValue {
								content = .text(firstText)
							} else {
								content = .parts(parts)
							}

							messages.append(ChatMessage(role: message.role, content: content, phase: message.phase))
					case .functionCallOutput(let output):
						messages.append(ChatMessage(role: .tool, content: .text(output.output), toolCallID: output.callId))
						default:
							continue
					}
				}
				return messages
		}
	}
}
