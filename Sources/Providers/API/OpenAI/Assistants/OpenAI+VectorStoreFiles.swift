//
//  OpenAI+VectorStoreFiles.swift
//
//
//  Created by Oliver Drobnik on 01.05.24.
//

import Foundation

extension OpenAI {
	/// Creates a vector store file by attaching an existing file to a specified vector store.
	///
	/// This function sends a POST request to the OpenAI API endpoint that manages vector store files.
	/// It takes a `vectorStoreId` and a `fileId` as parameters, constructs a request, and processes
	/// the response to return a `VectorStoreFile` object representing the newly created vector store file.
	///
	/// - Parameters:
	///   - vectorStoreId: The identifier of the vector store to which the file will be attached. This
	///                    must be a valid vector store ID already existing within OpenAI's system.
	///   - fileId: The identifier of the file to attach to the vector store. This file ID should correspond
	///             to a file that has been previously uploaded or managed within the OpenAI infrastructure.
	///
	/// - Returns: A `VectorStoreFile` object representing the file after it has been attached to the vector store.
	///
	/// - Throws: An error of type `Error` describing issues like network errors, data encoding problems,
	///           or issues returned from the server such as invalid IDs or authorization errors.
	///
	/// This method utilizes asynchronous network calls and requires proper error handling
	/// in the surrounding context where it is called.
	public func createVectorStoreFile(vectorStoreId: String, fileId: String) async throws -> VectorStoreFile {
		let fileRequest = VectorStoreFileRequest(fileId: fileId)

		let request = try self.createUrlRequest(httpMethod: "POST", path: "/v1/vector_stores/\(vectorStoreId)/files", body: fileRequest)

		let (data, response) = try await session.data(for: request)

		return try process(data: data, response: response)
	}

	func listVectorStoreFiles(vectorStoreId: String, limit: Int = 20, order: SortOrder = .descending, after: String? = nil, before: String? = nil, filter: FileStatus? = nil) async throws -> ListPagedResponse<VectorStoreFile> {
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

		let request = try self.createUrlRequest(path: "/v1/vector_stores/" + vectorStoreId + "/files", queryItems: queryItems)

		let (data, response) = try await session.data(for: request)

		let list: ListPagedResponse<VectorStoreFile> = try process(data: data, response: response)

		return list
	}

	func retrieveVectorStoreFile(vectorStoreId: String, fileId: String) async throws -> VectorStoreFile {
		let request = try self.createUrlRequest(path: "/v1/vector_stores/" + vectorStoreId + "/files/" + fileId)

		let (data, response) = try await session.data(for: request)

		return try process(data: data, response: response)
	}

	/// Waits until the specified VectorStoreFile has completed processing. Polls the file status
	/// at regular intervals and returns once the file is no longer in progress.
	///
	/// This function repeatedly checks the status of a specific file within a vector store,
	/// waiting for it to move out of the 'inProgress' state. It is useful for asynchronous workflows
	/// where subsequent operations depend on the completion of file processing.
	///
	/// - Parameters:
	///   - vectorStoreId: The identifier of the vector store that contains the file.
	///   - fileId: The identifier of the file whose completion status is to be monitored.
	///   - interval: The polling interval in seconds, defaults to 5 seconds. This is the delay between successive
	///               status checks to avoid excessive API calls.
	///
	/// - Returns: The VectorStoreFile once it is no longer in the 'inProgress' state, indicating that processing
	///            is complete or has failed.
	///
	/// - Throws: Throws an error if there is an API call failure during the status check. This could be due to network
	///           issues, access permissions, or if the identifiers provided do not correspond to valid entities.
	///
	@discardableResult func waitUntilVectorStoreFileIsReady(vectorStoreId: String, fileId: String, interval: TimeInterval = 5) async throws -> VectorStoreFile {
		while true {
			// Retrieve the current status of the VectorStore
			let polledStoreFile = try await retrieveVectorStoreFile(vectorStoreId: vectorStoreId, fileId: fileId)

			if polledStoreFile.status != .inProgress {
				return polledStoreFile
			}

			// Sleep for a few seconds before polling again
			try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
		}
	}

	@discardableResult func deleteVectorStoreFile(vectorStoreId: String, fileId: String) async throws -> Bool {
		let request = try self.createUrlRequest(httpMethod: "DELETE", path: "/v1/vector_stores/" + vectorStoreId + "/files/" + fileId)

		let (data, response) = try await session.data(for: request)

		let deletionStatus: DeletionStatus = try process(data: data, response: response)

		return deletionStatus.deleted
	}
}

internal struct VectorStoreFileRequest: Codable {
	let fileId: String
}
