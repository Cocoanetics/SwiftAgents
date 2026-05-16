//
//  ChatDelegate.swift
//
//
//  Created by Oliver Drobnik on 22.05.24.
//

import Foundation

public protocol GenericChat {
	var model: String { get }
}

public protocol ChatDelegate: AnyObject {
	func chat(_ chat: GenericChat, rateLimitExceededUntil date: Date)

	func chat(_ chat: GenericChat, didReceiveMessage text: String, role: Role, isComplete: Bool)

	func chat(_ chat: GenericChat, didReceive message: ChatMessage)

	func chat(_ chat: GenericChat, didReceive imageFile: ImageFile) async throws

	func chat(_ chat: GenericChat, didReceiveToolCalls toolCalls: [ToolCall])
}
