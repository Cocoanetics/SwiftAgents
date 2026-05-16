//
//  VectorStore.swift
//
//
//  Created by Oliver Drobnik on 01.05.24.
//

import Foundation

/**
 Represents a vector store object from the API, detailing configuration for a collection of processed files that can be used by the file_search tool.

 - SeeAlso: For more information, see [Vector Store API Documentation](https://platform.openai.com/docs/api-reference/vector-stores).
 */
public struct VectorStore: Codable {
    /// Unique identifier for the vector store, which can be referenced in API endpoints.
    public var id: String

    /// Type of object, which is always "vector_store".
    public var object: String

    /// The timestamp when the vector store was created.
    public var createdAt: Date

    /// Optional name of the vector store.
    public let name: String?

    /// The total number of bytes used by the files in the vector store.
    public var usageBytes: Int

    /// An object containing counts of files in different processing states.
    public var fileCounts: FileCounts

    /// The status of the vector store, which can be either "expired", "in_progress", or "completed". A status of
    /// "completed" indicates that the vector store is ready for use.
    public var status: FileStatus

    /// The expiration policy for the vector store.
    public var expiresAfter: ExpirationPolicy?

    /// The timestamp for when the vector store will expire, if applicable.
    public var expiresAt: Date?

    /// The timestamp for when the vector store was last active, if applicable.
    public var lastActiveAt: Date?

    /// Optional metadata providing additional information about the vector store in a key-value format.
    ///
    /// The set of metadata key-value pairs can be attached to a vector store object. This can be useful for storing
    /// additional information about the object in a structured format. Keys can be a maximum of 64 characters long, and
    /// values can be a maximum of 512 characters long.
    public var metadata: [String: String] = [:]
}

/**
 Represents a temporary vector store object with optional properties for creation or modification.

 This struct encapsulates the properties that can be optionally provided when creating or modifying a vector store.

 - Note: This struct is used as a request body for creating or modifying vector stores with optional parameters.

 - Parameters:
 - name: Optional. The name of the vector store.
 - expiresAfter: Optional. The expiration policy for the vector store.
 - metadata: Optional. Additional metadata to attach to the vector store.
 - fileIds: Optional. An array of file IDs to associate with the vector store.

 - Important: All properties are optional, allowing for flexible creation or modification of vector stores.

 - SeeAlso: For more information, see [Vector Store API Documentation](https://platform.openai.com/docs/api-reference/vector-stores).

 */
struct VectorStoreOptionals: Codable {
    /// Optional name of the vector store.
    let name: String?

    /// Optional expiration policy for the vector store.
    var expiresAfter: ExpirationPolicy?

    /// Optional metadata providing additional information about the vector store in a key-value format.
    var metadata: [String: String]?

    /// Optional array of file IDs associated with the vector store.
    var fileIds: [String]?
}

/**
 Represents an expiration policy for a vector store.
 */
public struct ExpirationPolicy: Codable {
    /// The anchor point for calculating expiration, e.g., "last_active_at".
    let anchor: String

    /// The number of days after which the vector store will expire.
    let days: Int
}
