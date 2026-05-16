//
//  VectorStoreFilesBatch.swift
//
//
//  Created by Oliver Drobnik on 02.05.24.
//

import Foundation

/**
 Represents a batch of files added to a vector store, detailing the batch's status and associated file counts.
 
 - SeeAlso: For more information, see [Vector Store Files Batch API Documentation](https://platform.openai.com/docs/api-reference/vector-stores-file-batches).
 */
struct VectorStoreFilesBatch: Codable {
	/// The unique identifier for the batch.
	let id: String

	/// The type of the object, always set to "vector_store.file_batch".
	let object: String

	/// The timestamp when the file batch was created.
	let createdAt: Date

	/// The identifier of the vector store to which the files are attached.
	let vectorStoreId: String

	/// The current status of the file batch.
	let status: FileStatus

	/// An object containing counts of files in different processing states.
	let fileCounts: FileCounts
}
