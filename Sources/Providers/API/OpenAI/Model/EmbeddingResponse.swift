//
//  EmbeddingResponse.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 19.04.24.
//

import Foundation

/// Represents an embedding response from the OpenAI API.
public struct EmbeddingResponse: Codable {
    /// The usage statistics for the embedding request.
    public struct Usage: Codable {
        /// The number of tokens in the prompt.
        public var promptTokens: Int

        /// The total number of tokens used in the completion, including the prompt.
        public var totalTokens: Int
    }

    /// The type of object, always "list".
    public let object: String

    /// An array of vectors.
    public let data: [EmbeddingVector]

    public let model: String

    public let usage: Usage
}
