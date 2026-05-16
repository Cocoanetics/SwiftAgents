//
//  ResponseInput.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.04.25.
//

import Foundation


extension Response
{
	/// Represents the input for a response, which can be text, image, or file
	public enum Input: Codable
	{
		/// Simple text input
		case text(String)
		
		/// Array of input elements (text, image URLs, etc.)
		case array([Response.Input.Element])
		
		public init(from decoder: Decoder) throws {
			let container = try decoder.singleValueContainer()
			if let string = try? container.decode(String.self) {
				self = .text(string)
			} else if let array = try? container.decode([Response.Input.Element].self) {
				self = .array(array)
			} else {
				throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid input format")
			}
		}
		
		public func encode(to encoder: Encoder) throws {
			var container = encoder.singleValueContainer()
			switch self {
			case .text(let string):
				try container.encode(string)
			case .array(let array):
				try container.encode(array)
			}
		}
	}
}
