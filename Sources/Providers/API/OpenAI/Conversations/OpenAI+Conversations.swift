//
//  OpenAI+Conversations.swift
//
//
//  Created by Oliver Drobnik on 14.04.26.
//

import Foundation

extension OpenAI {

	/// Creates a conversation on the OpenAI platform with optional initial items and metadata.
	///
	/// - Parameters:
	///   - items: Optional. An array of input items to include in the conversation context (up to 20 items).
	///   - metadata: Optional. Key-value pairs providing additional information about the conversation.
	///
	/// - Returns: Returns a `Conversation` object containing details of the newly created conversation.
	///
	/// - SeeAlso: [Create Conversation API](https://platform.openai.com/docs/api-reference/conversations/create)
	public func createConversation(
		items: [Response.Input.Element]? = nil,
		metadata: [String: String]? = nil
	) async throws -> Conversation {
		let details = ConversationOptionals(items: items, metadata: metadata)
		let request = try self.createUrlRequest(httpMethod: "POST", path: "/v1/conversations", body: details)

		let (data, response) = try await URLSession.shared.data(for: request)

		return try process(data: data, response: response)
	}

	/// Retrieves a conversation from the OpenAI platform using its unique identifier.
	///
	/// - Parameter id: The unique identifier of the conversation to retrieve.
	///
	/// - Returns: Returns a `Conversation` object containing the details of the retrieved conversation.
	///
	/// - SeeAlso: [Retrieve Conversation API](https://platform.openai.com/docs/api-reference/conversations/retrieve)
	public func retrieveConversation(id: String) async throws -> Conversation {
		let request = try self.createUrlRequest(path: "/v1/conversations/" + id)

		let (data, response) = try await URLSession.shared.data(for: request)

		return try process(data: data, response: response)
	}

	/// Updates a conversation on the OpenAI platform using its unique identifier.
	/// Currently only metadata can be updated.
	///
	/// - Parameters:
	///   - id: The unique identifier of the conversation to update.
	///   - metadata: Optional. Key-value pairs providing additional information about the conversation.
	///
	/// - Returns: Returns the updated `Conversation` object.
	///
	/// - SeeAlso: [Update Conversation API](https://platform.openai.com/docs/api-reference/conversations/update)
	public func updateConversation(
		id: String,
		metadata: [String: String]? = nil
	) async throws -> Conversation {
		let details = ConversationOptionals(metadata: metadata)
		let request = try self.createUrlRequest(httpMethod: "POST", path: "/v1/conversations/" + id, body: details)

		let (data, response) = try await URLSession.shared.data(for: request)

		return try process(data: data, response: response)
	}

	/// Deletes a conversation from the OpenAI platform using its unique identifier.
	/// Note: Items in the conversation will not be deleted.
	///
	/// - Parameter id: The unique identifier of the conversation to delete.
	///
	/// - Returns: Returns a boolean indicating whether the deletion was successful.
	///
	/// - SeeAlso: [Delete Conversation API](https://platform.openai.com/docs/api-reference/conversations/delete)
	@discardableResult
	public func deleteConversation(id: String) async throws -> Bool {
		let request = try self.createUrlRequest(httpMethod: "DELETE", path: "/v1/conversations/" + id)

		let (data, response) = try await URLSession.shared.data(for: request)

		let deletionStatus: ConversationDeletedResource = try process(data: data, response: response)

		return deletionStatus.deleted
	}
}
