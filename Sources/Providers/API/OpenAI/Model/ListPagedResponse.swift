//
//  EmbeddingResponse.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 19.04.24.
//

import Foundation

/// Represents an embedding response from the OpenAI API. The generic parameter is a JSON object represented in the data
public struct ListPagedResponse<C: Codable>: Codable {
	/// The type of object, always "list".
	public let object: String

	/// An array of objects.
	public let data: [C]

	public let firstId: String?
	public let lastId: String?
	public let hasMore: Bool
}
