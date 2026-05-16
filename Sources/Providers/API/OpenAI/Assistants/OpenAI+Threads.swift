//
//  OpenAI+Threads.swift
//
//
//  Created by Oliver Drobnik on 02.05.24.
//

import Foundation

extension OpenAI {
	/**
	 Creates a thread on the OpenAI platform with optional initial messages, tool resources, and metadata.
	 
	 - Parameters:
	   - messages: Optional. An array of messages to start the thread with.
	   - toolResources: Optional. Resources specific to the tools used within the thread.
	   - metadata: Optional. Key-value pairs providing additional information about the thread.
	 
	 - Returns: Returns a `Thread` object containing details of the newly created thread.
	 
	 - SeeAlso: [Create Thread API](https://platform.openai.com/docs/api-reference/threads/createThread)
	 */
	public func createThread(messages: [MessageCreation]? = nil,
					  toolResources: ToolResources? = nil,
					  metadata: [String: String]? = nil) async throws -> Thread {
		let details = ThreadOptionals(messages: messages, toolResources: toolResources, metadata: metadata)
		let request = try self.createUrlRequest(httpMethod: "POST", path: "/v1/threads", body: details)

		let (data, response) = try await URLSession.shared.data(for: request)

		return try process(data: data, response: response)
	}

	/**
	 Retrieves a thread from the OpenAI platform using the thread's unique identifier.
	 
	 - Parameter id: The unique identifier of the thread to retrieve.
	 
	 - Returns: Returns a `Thread` object containing the details of the retrieved thread.
	 
	 - SeeAlso: [Get Thread API](https://platform.openai.com/docs/api-reference/threads/getThread)
	 */
	public func retrieveThread(id: String) async throws -> Thread {
		let request = try self.createUrlRequest(path: "/v1/threads/" + id)

		let (data, response) = try await URLSession.shared.data(for: request)

		return try process(data: data, response: response)
	}

	/**
	 Modifies an existing thread on the OpenAI platform using the thread's unique identifier.
	 This function updates the tool resources and metadata associated with the specified thread.
	 
	 - Parameters:
	   - id: The unique identifier of the thread to modify.
	   - toolResources: Optional. Resources specific to the tools used within the thread. For example, the code_interpreter tool requires a list of file IDs, while the file_search tool requires a list of vector store IDs.
	   - metadata: Optional. Key-value pairs providing additional information about the thread. Keys can be a maximum of 64 characters long and values can be a maximum of 512 characters long.
	 
	 - Returns: Returns the modified `Thread` object containing updated details.
	 
	 - SeeAlso: [Modify Thread API](https://platform.openai.com/docs/api-reference/threads/modifyThread)
	 */
	public func modifyThread(id: String,
					  toolResources: ToolResources? = nil,
					  metadata: [String: String]? = nil) async throws -> Thread {
		let threadDetails = ThreadOptionals(toolResources: toolResources, metadata: metadata)
		let request = try self.createUrlRequest(httpMethod: "POST", path: "/v1/threads/" + id, body: threadDetails)

		let (data, response) = try await URLSession.shared.data(for: request)

		return try process(data: data, response: response)
	}

	/**
	 Deletes a thread from the OpenAI platform using the thread's unique identifier.
	 
	 - Parameter id: The unique identifier of the thread to delete.
	 
	 - Returns: Returns a boolean indicating whether the deletion was successful.
	 
	 - SeeAlso: [Delete Thread API](https://platform.openai.com/docs/api-reference/threads/deleteThread)
	 */
	@discardableResult
	func deleteThread(id: String) async throws -> Bool {
		let request = try self.createUrlRequest(httpMethod: "DELETE", path: "/v1/threads/" + id)

		let (data, response) = try await URLSession.shared.data(for: request)

		let deletionStatus: DeletionStatus = try process(data: data, response: response)

		return deletionStatus.deleted
	}
}
