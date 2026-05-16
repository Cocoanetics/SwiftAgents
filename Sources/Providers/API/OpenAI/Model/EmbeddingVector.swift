//
//  EmbeddingVector.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 19.04.24.
//

import Foundation

/// Represents an embedding vector return by the embeddings  API.
public struct EmbeddingVector: Codable {
    /// The type of object, always "embedding".
    public let object: String

    /// A list of messages describing the conversation so far.
    public let index: Int

    /// An array of vector values
    public let embedding: Vector
}
