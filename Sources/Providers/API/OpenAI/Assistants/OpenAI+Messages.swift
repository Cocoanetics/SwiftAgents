//
//  OpenAI+Messages.swift
//
//
//  Created by Oliver Drobnik on 02.05.24.
//

import Foundation

extension OpenAI {
	/**
		 Creates a message in a specified thread on the OpenAI platform.
		 
		 - Parameters:
		   - threadId: The unique identifier of the thread where the message will be created.
		   - role: The role of the entity creating the message, either "user" or "assistant".
		   - content: The content of the message, potentially including text and/or images.
		   - attachments: Optional. A list of attachments linked to the message.
		   - metadata: Optional. Key-value pairs providing additional information about the message.
		 
		 - Returns: Returns a `Message` object containing the details of the newly created message.
		 
		 - SeeAlso: [Create Message API](https://platform.openai.com/docs/api-reference/messages/createMessage)
		 */
	@discardableResult
	func createMessage(threadId: String, role: Role, content: String, attachments: [Attachment]? = nil, metadata: [String: String]? = nil) async throws -> Message {
		let details = MessageCreation(role: role, content: content, attachments: attachments, metadata: metadata)
		let request = try self.createUrlRequest(httpMethod: "POST", path: "/v1/threads/\(threadId)/messages", body: details)

		let (data, response) = try await URLSession.shared.data(for: request)

		return try process(data: data, response: response)
	}

	/**
	 Lists messages of a specific thread on the OpenAI platform, providing pagination control.
	 
	 - Parameters:
	 - threadId: The unique identifier of the thread whose messages are to be listed.
	 - limit: Optional. The maximum number of messages to return, default is 20.
	 - order: Optional. The order of the messages returned.
	 - after: Optional. A cursor for pagination; specifies an object ID to list messages after it.
	 - before: Optional. A cursor for pagination; specifies an object ID to list messages before it.
	 - runId: Optional. Filter messages by the run ID that generated them.
	 
	 - Returns: Returns a paginated list of messages for the given thread.
	 
	 - SeeAlso: [List Messages API](https://platform.openai.com/docs/api-reference/messages/listMessages)
	 */
	func listMessages(threadId: String, limit: Int = 20, order: SortOrder = .descending, after: String? = nil, before: String? = nil, runId: String? = nil) async throws -> ListPagedResponse<Message> {
		var queryItems: [URLQueryItem] = [
			URLQueryItem(name: "limit", value: String(limit)),
			URLQueryItem(name: "order", value: order.rawValue)
		]

		if let after = after {
			queryItems.append(URLQueryItem(name: "after", value: after))
		}

		if let before = before {
			queryItems.append(URLQueryItem(name: "before", value: before))
		}

		if let runId = runId {
			queryItems.append(URLQueryItem(name: "run_id", value: runId))
		}

		let request = try self.createUrlRequest(path: "/v1/threads/\(threadId)/messages", queryItems: queryItems)

		let (data, response) = try await URLSession.shared.data(for: request)

		return try process(data: data, response: response)
	}

	/**
	 Retrieves a message from the OpenAI platform using the thread's unique identifier and the message's unique identifier.
	 
	 - Parameters:
	   - threadId: The unique identifier of the thread to which the message belongs.
	   - messageId: The unique identifier of the message to retrieve.
	 
	 - Returns: Returns a `Message` object containing the details of the retrieved message.
	 
	 - SeeAlso: [Retrieve Message API](https://platform.openai.com/docs/api-reference/messages/getMessage)
	 */
	func retrieveMessage(threadId: String, messageId: String) async throws -> Message {
		let request = try self.createUrlRequest(path: "/v1/threads/\(threadId)/messages/\(messageId)")

		let (data, response) = try await URLSession.shared.data(for: request)

		return try process(data: data, response: response)
	}

	/**
	 Modifies a message on the OpenAI platform using the thread's unique identifier and the message's unique identifier.
	 
	 - Parameters:
	   - threadId: The unique identifier of the thread to which the message belongs.
	   - messageId: The unique identifier of the message to modify.
	   - metadata: Optional. Key-value pairs providing additional information about the message. Keys can be a maximum of 64 characters long and values can be a maximum of 512 characters long.
	 
	 - Returns: Returns the modified `Message` object containing updated details.
	 
	 - SeeAlso: [Modify Message API](https://platform.openai.com/docs/api-reference/messages/modifyMessage)
	 */
	func modifyMessage(
		threadId: String,
		messageId: String,
		metadata: [String: String]
	) async throws -> Message {
		let body = ["metadata": metadata]
		let request = try self.createUrlRequest(httpMethod: "POST", path: "/v1/threads/\(threadId)/messages/\(messageId)", body: body)

		let (data, response) = try await URLSession.shared.data(for: request)

		return try process(data: data, response: response)
	}

	/**
	 Deletes a message from the OpenAI platform using the thread's unique identifier and the message's unique identifier.
	 
	 - Parameters:
	   - threadId: The unique identifier of the thread to which the message belongs.
	   - messageId: The unique identifier of the message to delete.
	 
	 - Returns: Returns a boolean indicating whether the deletion was successful.
	 
	 - SeeAlso: [Delete Message API](https://platform.openai.com/docs/api-reference/messages/deleteMessage)
	 */
	@discardableResult
	func deleteMessage(threadId: String, messageId: String) async throws -> Bool {
		let request = try self.createUrlRequest(httpMethod: "DELETE", path: "/v1/threads/\(threadId)/messages/\(messageId)")

		let (data, response) = try await URLSession.shared.data(for: request)

		let deletionStatus: DeletionStatus = try process(data: data, response: response)

		return deletionStatus.deleted
	}

}
