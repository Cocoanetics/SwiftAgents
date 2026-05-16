//
//  EmbeddingRequest.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 19.04.24.
//

import Foundation

/// Represents an embedding request to the OpenAI API.
public struct EmbeddingRequest: Codable {
	/// The ID of the model to use for generating the response.
	public let input: String

	/// A list of messages describing the conversation so far.
	public let model: String
}
