//
//  OllamaEmbeddingResponse.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 19.04.24.
//

import Foundation

/// Represents an embedding response from the OpenAI API.
public struct OllamaEmbeddingResponse: Codable
{
	/// A single vector.
	public let embedding: Vector
}
