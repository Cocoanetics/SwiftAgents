//
//  GPTImageOptions.swift
//  
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

/// Options specific to GPT Image
public struct GPTImageOptions: ImageGenerationOptions, Codable { 
	// Size, Quality, ImageBackground, ImageModeration, ImageOutputFormat enums defined in extensions
	
	/// The number of images to generate (1-10)
	public let count: Int
	/// The size of the generated images
	public let size: Size 
	/// The quality of the image
	public let quality: Quality 
	/// The background style
	public let background: ImageBackground 
	/// The moderation level
	public let moderation: ImageModeration 
	/// The compression level (0-100%)
	public let outputCompression: Int?
	/// The output format
	public let outputFormat: ImageOutputFormat 
	/// A unique identifier representing your end-user
	public let user: String?
	
	public init(
		count: Int = 1,
		size: Size = .auto, 
		quality: Quality = .auto, 
		background: ImageBackground = .auto, 
		moderation: ImageModeration = .auto, 
		outputCompression: Int? = nil,
		outputFormat: ImageOutputFormat = .png, 
		user: String? = nil
	) {
		self.count = count
		self.size = size
		self.quality = quality
		self.background = background
		self.moderation = moderation
		self.outputCompression = outputCompression
		self.outputFormat = outputFormat
		self.user = user
	}
} 