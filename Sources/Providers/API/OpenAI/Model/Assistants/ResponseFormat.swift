//
//  ResponseFormat.swift
//
//
//  Created by Oliver Drobnik on 30.04.24.
//

import Foundation

/// Specifies the format that the model must output.
public enum ResponseFormat: Codable {
	/// Automatically determines the response format.
	/// This is typically used when the model decides the best output format based on the input or context.
	case auto

	/// Specifies that the response must be in plain text format.
	/// This format is straightforward and typically used for text-based outputs.
	case text

	/// Specifies that the response must be a JSON object.
	/// This format is used to ensure the output is structured as valid JSON, making it ideal for API responses.
	/// Note: This format should only be used if all tools are of the type 'function'.
	case jsonObject

	/// Initializes from decoder attempting to discern between the string "auto" and dictionary types for "text" and "json_object".
	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if let stringValue = try? container.decode(String.self) {
			switch stringValue {
			case "auto":
				self = .auto
			default:
				throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid value for ResponseFormat")
			}
		} else {
			let dictValue = try container.decode([String: String].self)
			switch dictValue["type"] {
			case "text":
				self = .text
			case "json_object":
				self = .jsonObject
			default:
				throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid type for ResponseFormat dictionary")
			}
		}
	}

	/// Encodes this instance into the given encoder.
	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .auto:
			try container.encode("auto")
		case .text:
			try container.encode(["type": "text"])
		case .jsonObject:
			try container.encode(["type": "json_object"])
		}
	}
}
