//
// OpenAIAPI+VectorStores.swift
//
//
//  Created by Oliver Drobnik on 01.05.24.
//

import Foundation

extension OpenAI
{
	/**
	 Creates a vector store on the OpenAI platform.
	 
	 - Parameters:
	   - name: Optional. The name of the vector store.
	   - policy: Optional. Expiration policy for the vector store.
	   - metadata: Optional. Metadata for the vector store as a dictionary.
	   - fileIds: Optional. Array of file IDs to be included in the vector store.
	   
	 - Returns: Returns a `VectorStore` object containing details of the newly created store.
	 
	 - Throws: Throws an error if there is any problem in creating the store or processing the response.
	 
	 - SeeAlso: [Create Vector Store](https://platform.openai.com/docs/api-reference/vector-stores/create)
	 */
	func createVectorStore(name: String? = nil, expiresAfter policy: ExpirationPolicy? = nil, metadata: [String: String] = [:], fileIds: [String]? = nil) async throws -> VectorStore
	{
		let vectorStore = VectorStoreOptionals(name: name, expiresAfter: policy, metadata: metadata, fileIds: fileIds)
		
		let request = try self.createUrlRequest(httpMethod: "POST", path: "/v1/vector_stores", body: vectorStore)

		let (data, response) = try await session.data(for: request)
		
		return try process(data: data, response: response)
	}
	
	/**
	 Modifies a vector store with the specified parameters.

	 - Parameters:
	   - id: The identifier of the vector store to modify.
	   - name: Optional. The new name for the vector store.
	   - expiresAfter: Optional. The new expiration policy for the vector store.
	   - metadata: Optional. Additional metadata to attach to the vector store.
	 - Returns: The modified vector store object.
	 - Throws: An error if the API call fails.
	 */
	func modifyVectorStore(id: String, name: String? = nil, expiresAfter: ExpirationPolicy? = nil, metadata: [String: String]? = nil) async throws -> VectorStore {
		// Construct the request body
		let requestBody = VectorStoreOptionals(name: name, expiresAfter: expiresAfter, metadata: metadata, fileIds: nil)
		
		// Create the URL path
		let endpoint = "/v1/vector_stores/\(id)"
		
		// Create the URL request
		let request = try createUrlRequest(httpMethod: "POST", path: endpoint, body: requestBody)
		
		// Perform the API call
		let (data, response) = try await session.data(for: request)
		
		// Process the response data
		return try process(data: data, response: response)
	}
	
	/**
	 Fetches a paginated list of vector stores.

	 - Parameters:
	   - limit: The maximum number of vector stores to return per page. Default is 20.
	   - order: The order in which vector stores should be returned.
	   - after: A cursor for pagination; returns the next page of results after this cursor.
	   - before: A cursor for pagination; returns the previous page of results before this cursor.

	 - Returns: A paginated response containing vector stores.

	 - Throws: An error if the request fails or if the response cannot be processed.
	 
	 - SeeAlso: [OpenAI Platform API Documentation - List Vector Stores](https://platform.openai.com/docs/api-reference/vector-stores/list)
	 */
	func listVectorStores(limit: Int = 20, order: SortOrder = .descending, after: String? = nil, before: String? = nil) async throws -> ListPagedResponse<VectorStore>
	{
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
		
		let request = try self.createUrlRequest(path: "/v1/vector_stores", queryItems: queryItems)
		
		let (data, response) = try await session.data(for: request)
		
		let list: ListPagedResponse<VectorStore> = try process(data: data, response: response)
		
		return list
	}
	
	/**
	 Returns an asynchronous stream of all vector stores.

	 - Parameters:
	   - limit: The maximum number of vector stores to return. If `nil`, all vector stores will be returned. Default is `nil`.
	   - order: The order in which vector stores should be returned.

	 - Returns: An asynchronous stream that yields vector stores.

	 - Note: This method internally fetches vector stores in pages and streams them asynchronously.

	 - Throws: An error if the request fails or if the response cannot be processed.
	 */
	func listVectorStoresStream(limit: Int? = nil, order: SortOrder = .descending) -> AsyncThrowingStream<VectorStore, Error>
	{
		return AsyncThrowingStream { continuation in
			
			Task 
			{
				do {
					var count = 0
					
					var after: String?
					var hasMore: Bool = false
					
					repeat
					{
						let page = try await self.listVectorStores(order: order, after: after)

						hasMore = page.hasMore
						after = page.lastId

						for vectorStore in page.data
						{
							continuation.yield(vectorStore)
							count += 1
							
							if let limit = limit,
							   count >= limit
							{
								hasMore = false
								break
							}
						}
						
					} while hasMore
								
					continuation.finish()
				}
				catch let error
				{
					continuation.finish(throwing: error)
				}
			}
		}
	}
	
	/**
	 Retrieves a vector store by its identifier.

	 - Parameter id: The unique identifier of the vector store to retrieve.

	 - Returns: The vector store with the specified identifier.

	 - Throws: An error if the request fails or if the response cannot be processed.

	 - SeeAlso: [Retrieve Vector Store](https://platform.openai.com/docs/api-reference/vector-stores/retrieve)
	 */
	func retrieveVectorStore(id: String) async throws -> VectorStore
	{
		let request = try self.createUrlRequest(path: "/v1/vector_stores/" + id)
		
		let (data, response) = try await session.data(for: request)
		
		return try process(data: data, response: response)
	}
	
	/**
	 Waits until all files in the specified VectorStore have been processed.

	 This function repeatedly checks the status of the VectorStore, waiting for all files
	 to move out of the 'inProgress' state. It is useful for workflows that require
	 all files within a store to be fully processed before proceeding.

	 - Parameters:
	   - id: The identifier of the VectorStore to monitor.
	   - interval: The polling interval in seconds, defaults to 5 seconds. This parameter controls
				   how often the VectorStore's status is checked to minimize API calls and system load.

	 - Returns: The VectorStore once all files within it are no longer in progress, indicating that
				processing is complete. This could include scenarios where files have completed successfully
				or have failed to process.

	 - Throws: Throws an error if there is an API call failure, which could be due to network issues,
			   permissions problems, or the identifier not corresponding to a valid VectorStore.

	 - Note: This function blocks until all files in the VectorStore are no longer in progress.

	 - SeeAlso: [Retrieve Vector Store](https://platform.openai.com/docs/api-reference/vector-stores/retrieve)
	 */
	@discardableResult func waitUntilVectorStoreIsReady(id: String, interval: TimeInterval = 5) async throws -> VectorStore {
		while true {
			// Retrieve the current status of the VectorStore
			let polledStore = try await retrieveVectorStore(id: id)
			
			print("Current file count in progress: \(polledStore.fileCounts.inProgress)")

			if polledStore.fileCounts.inProgress == 0 {
				return polledStore
			}
			
			// Sleep for a few seconds before polling again to manage API request frequency
			try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
		}
	}
	
	/**
	 Deletes a VectorStore by its identifier.

	 - Parameter id: The identifier of the VectorStore to delete.

	 - Returns: A boolean indicating whether the VectorStore was successfully deleted.

	 - Throws: An error if the deletion fails, which could be due to network issues,
			   permissions problems, or the identifier not corresponding to a valid VectorStore.

	 - SeeAlso: [OpenAI Platform API Documentation - Delete Vector Store](https://platform.openai.com/docs/api-reference/vector-stores/delete)
	 */
	@discardableResult func deleteVectorStore(id: String) async throws -> Bool
	{
		let request = try self.createUrlRequest(httpMethod: "DELETE", path: "/v1/vector_stores/" + id)
		
		let (data, response) = try await session.data(for: request)
		
		let deletionStatus: DeletionStatus = try process(data: data, response: response)
		
		return deletionStatus.deleted
	}
}
