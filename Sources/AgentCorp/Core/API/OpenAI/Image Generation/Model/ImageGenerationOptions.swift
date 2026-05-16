//
//  ImageGenerationOptions.swift
//
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

/// Base protocol for image generation options
public protocol ImageGenerationOptions {
	/// The number of images to generate
	var count: Int { get }
	/// A unique identifier representing your end-user
	var user: String? { get }
} 