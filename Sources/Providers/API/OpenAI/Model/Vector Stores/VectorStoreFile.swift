//
//  File.swift
//  
//
//  Created by Oliver Drobnik on 01.05.24.
//

import Foundation

/**
 Represents a file attached to a vector store.
 
 - SeeAlso: For more information, see [Vector Store Files API Documentation](https://platform.openai.com/docs/api-reference/vector-stores-files).
 */
public struct VectorStoreFile: Codable
{
	/// The identifier, which can be referenced in API endpoints.
	public let id: String

	/// The object type, which is always "vector_store.file".
	public let object: String
	
	/// The total vector store usage in bytes. Note that this may be different from the original file size.
	public let usageBytes: Int

	/// The timestamp when the vector store file was created, represented as a Date.
	public let createdAt: Date

	/// The ID of the vector store that the file is attached to.
	public let vectorStoreId: String

	/// The status of the vector store file, which can be either in_progress, completed, cancelled, or failed.
	public let status: FileStatus

	/// The last error associated with this vector store file, if any.
	public let lastError: LastError?
}
