//
//  OpenAI+VectoreStoreFilesBatch.swift
//
//
//  Created by Oliver Drobnik on 02.05.24.
//

import Foundation

extension OpenAI
{
	/// Creates a file batch in a specific vector store.
	///
	/// - Parameters:
	///   - vectorStoreId: The identifier of the vector store to which the files will be attached.
	///   - fileIds: An array of file IDs to be included in the batch.
	/// - Returns: A `VectorStoreFilesBatch` representing the newly created file batch.
	/// - Throws: An error if the API call fails.
	///
	func createVectorStoreFilesBatch(vectorStoreId: String, fileIds: [String]) async throws -> VectorStoreFilesBatch 
	{
		let endpoint = "/v1/vector_stores/\(vectorStoreId)/file_batches"
		let requestBody = ["file_ids": fileIds]
		let request = try createUrlRequest(httpMethod: "POST", path: endpoint, body: requestBody)
		let (data, response) = try await session.data(for: request)
		return try process(data: data, response: response)
	}
	
	/// Retrieves a specific file batch from a vector store.
	   ///
	   /// - Parameters:
	   ///   - vectorStoreId: The identifier of the vector store.
	   ///   - batchId: The identifier of the file batch to retrieve.
	   /// - Returns: A `VectorStoreFilesBatch` object representing the file batch.
	   /// - Throws: An error if the API call fails.
	///
	   func retrieveVectorStoreFilesBatch(vectorStoreId: String, batchId: String) async throws -> VectorStoreFilesBatch 
	{
		   let endpoint = "/v1/vector_stores/\(vectorStoreId)/file_batches/\(batchId)"
		   let request = try createUrlRequest(path: endpoint)
		   let (data, response) = try await session.data(for: request)
		   return try process(data: data, response: response)
	   }
	
	/// Lists all file batches in a vector store with optional pagination and filtering.
	///
	/// - Parameters:
	///   - vectorStoreId: The identifier of the vector store.
	///   - limit: Maximum number of batches to retrieve (default is 20).
	///   - order: Sort order of returned batches.
	///   - after: A cursor for use in pagination, specifying the ID of the last item in the previous fetch.
	///   - before: A cursor for use in pagination, specifying the ID of the first item in the subsequent fetch.
	///   - filter: Optional filter for batch status.
	/// - Returns: A `ListPagedResponse<VectorStoreFilesBatch>` containing the list of batches.
	/// - Throws: An error if the API call fails.
	func listVectorStoreFilesBatches(vectorStoreId: String, limit: Int = 20, order: SortOrder = .descending, after: String? = nil, before: String? = nil, filter: FileStatus? = nil) async throws -> ListPagedResponse<VectorStoreFilesBatch> 
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
		
		if let filter = filter {
			queryItems.append(URLQueryItem(name: "filter", value: filter.rawValue))
		}
		
		let endpoint = "/v1/vector_stores/\(vectorStoreId)/file_batches"
		let request = try createUrlRequest(path: endpoint, queryItems: queryItems)
		
		let (data, response) = try await session.data(for: request)
		return try process(data: data, response: response)
	}
	
	/// Cancels a file batch in a specific vector store.
	///
	/// This function sends a POST request to the OpenAI API endpoint that handles the cancellation of file batches.
	/// It attempts to cancel the processing of files in the batch as soon as possible.
	///
	/// - Parameters:
	///   - vectorStoreId: The identifier of the vector store that contains the file batch.
	///   - batchId: The identifier of the file batch to cancel.
	/// - Returns: A `VectorStoreFilesBatch` object representing the batch after the cancellation attempt.
	/// - Throws: An error if the API call fails, such as network errors, invalid parameters, or server issues.
	///
	func cancelVectorStoreFilesBatch(vectorStoreId: String, batchId: String) async throws -> VectorStoreFilesBatch 
	{
		let endpoint = "/v1/vector_stores/\(vectorStoreId)/file_batches/\(batchId)/cancel"
		let request = try createUrlRequest(httpMethod: "POST", path: endpoint)
		let (data, response) = try await session.data(for: request)
		return try process(data: data, response: response)
	}
	
	/// Waits until a vector store files batch is ready, i.e., not in progress.
	///
	/// - Parameters:
	///   - vectorStoreId: The identifier of the vector store containing the batch.
	///   - batchId: The identifier of the batch to wait for.
	///   - interval: The interval between status checks in seconds (default is 5 seconds).
	/// - Returns: The batch object once it's not in progress.
	/// 
	@discardableResult
	func waitUntilVectorStoreBatchIsReady(vectorStoreId: String, batchId: String, interval: TimeInterval = 5) async throws -> VectorStoreFilesBatch {
		while true {
			// Retrieve the current status of the batch
			let polledBatch = try await retrieveVectorStoreFilesBatch(vectorStoreId: vectorStoreId, batchId: batchId)
			
			if polledBatch.status != .inProgress {
				return polledBatch
			}
			
			// Sleep for a few seconds before polling again
			try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
		}
	}
}
