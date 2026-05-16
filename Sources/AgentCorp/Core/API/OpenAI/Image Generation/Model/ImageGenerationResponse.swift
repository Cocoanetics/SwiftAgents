//
//  ImageGenerationResponse.swift
//
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

struct ImageGenerationResponse: Codable
{
	let created: Date
	let images: [ImageData]
	
	enum CodingKeys: String, CodingKey {
		case created
		case images = "data"
	}
}
