//
//  ModelListResponse.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 19.04.24.
//

import Foundation

/// Represents a list of models returned by the OpenAI API.
public struct ModelListResponse: Codable, Sendable
{
	/// The type of object, expected to be "list" when provided.
	public let object: String?
	
	/// An array of `Model` objects.
	public let data: [Model]
	
	private enum CodingKeys: String, CodingKey {
		case object
		case data
		case models
	}
	
	public init(object: String?, data: [Model]) {
		self.object = object
		self.data = data
	}
	
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		self.object = try container.decodeIfPresent(String.self, forKey: .object)
		
		if let data = try container.decodeIfPresent([Model].self, forKey: .data) {
			self.data = data
		} else if let models = try container.decodeIfPresent([Model].self, forKey: .models) {
			self.data = models
		} else {
			throw DecodingError.keyNotFound(
				CodingKeys.data,
				DecodingError.Context(
					codingPath: decoder.codingPath,
					debugDescription: "Expected 'data' or 'models' array in model list response"
				)
			)
		}
	}
	
	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encodeIfPresent(object, forKey: .object)
		try container.encode(data, forKey: .data)
	}
}
