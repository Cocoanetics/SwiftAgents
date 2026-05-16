//
//  TruncationStrategy.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 24.04.25.
//

import Foundation

extension Response {
	/// The truncation strategy to use for the model response.
	public enum TruncationStrategy: String, Codable, Sendable {
		/// If the context of this response and previous ones exceeds the model's context window size,
		/// the model will truncate the response to fit the context window by dropping input items
		/// in the middle of the conversation.
		case auto

		/// If a model response will exceed the context window size for a model,
		/// the request will fail with a 400 error. This is the default behavior.
		case disabled
	}
}
