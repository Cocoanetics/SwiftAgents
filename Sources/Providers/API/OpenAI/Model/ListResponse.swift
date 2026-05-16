//
//  ListResponse.swift
//
//
//  Created by Oliver Drobnik on 01.05.24.
//

import Foundation

/// Represents an embedding response from the OpenAI API. The generic parameter is a JSON object represented in the data
public struct ListResponse<C: Codable>: Codable, Sendable where C: Sendable {
	/// The type of object, always "list".
	public let object: String

	/// An array of objects.
	public let data: [C]

	public init(object: String = "list", data: [C]) {
		self.object = object
		self.data = data
	}
}
