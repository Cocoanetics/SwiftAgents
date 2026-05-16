//
//  Dalle3Options.swift
//  
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

/// Options specific to DALL-E 3
public struct Dalle3Options: ImageGenerationOptions, Codable {
	// Size, Quality, Style enums defined in extensions

	/// The number of images to generate (always 1 for DALL-E 3)
	public let count: Int
	/// The size of the generated images
	public let size: Size
	/// The quality of the image
	public let quality: Quality
	/// The format in which the generated images are returned
	public let responseFormat: ImageResponseFormat
	/// The style of the generated images
	public let style: Style
	/// A unique identifier representing your end-user
	public let user: String?

	public init(
		size: Size = .large,
		quality: Quality = .standard,
		responseFormat: ImageResponseFormat = .url,
		style: Style = .vivid,
		user: String? = nil
	) {
		self.count = 1
		self.size = size
		self.quality = quality
		self.responseFormat = responseFormat
		self.style = style
		self.user = user
	}
}
