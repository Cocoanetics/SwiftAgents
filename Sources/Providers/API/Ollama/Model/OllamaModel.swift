//
//  OllamaModel.swift
//  
//
//  Created by Oliver Drobnik on 24.04.24.
//

import Foundation

/// Represents a single model returned by the OpenAI API.
public struct OllamaModel: Decodable {
	let name: String
	let model: String
	let modifiedAt: Date
	let size: Int
	let digest: String
	let details: Details

	struct Details: Decodable {
		let parentModel: String
		let format: String
		let family: String
		let families: [String]
		let parameterSize: String
		let quantizationLevel: String
	}
}
