//
//  OllamaEmbeddingRequest.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 19.04.24.
//

import Foundation

/// Represents an embedding request to the Ollama API.
public struct OllamaEmbeddingRequest: Codable {
	/// The ID of the model to use for generating the response.
	public let prompt: String

	/// A list of messages describing the conversation so far.
	public let model: String
}
