//
//  Dalle2Options.swift
//  
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

/// Options specific to DALL-E 2
public struct Dalle2Options: ImageGenerationOptions, Codable {
	// Size enum defined in Dalle2Options+Size.swift
	
	/// The number of images to generate (1-10)
	public let count: Int
	/// The size of the generated images
	public let size: Size // Uses type defined in extension
	/// The format in which the generated images are returned
	public let responseFormat: ImageResponseFormat
	/// A unique identifier representing your end-user
	public let user: String?
	
	public init(
		count: Int = 1,
		size: Size = .large, // Uses type defined in extension
		responseFormat: ImageResponseFormat = .url,
		user: String? = nil
	) {
		self.count = count
		self.size = size
		self.responseFormat = responseFormat
		self.user = user
	}
} 
