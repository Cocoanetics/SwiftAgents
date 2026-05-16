//
//  Usage.swift
//
//
//  Created by Oliver Drobnik on 03.05.24.
//

import Foundation

/// The usage statistics for the completion request.
public struct Usage: Codable, Sendable {
	/// The number of tokens in the prompt.
	public var promptTokens: Int = 0

	/// The number of tokens in the generated completion.
	public var completionTokens: Int = 0

	/// The total number of tokens used in the completion, including the prompt.
	public var totalTokens: Int = 0
}
