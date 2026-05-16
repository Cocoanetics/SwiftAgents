//
//  ImageGenerationModel.swift
//
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

/// The model to use for image generation
public enum ImageGenerationModel {
	/// DALL-E 2 model with specific options
	case dalle2(Dalle2Options)
	/// DALL-E 3 model with specific options
	case dalle3(Dalle3Options)
	/// GPT Image model with specific options
	case gptImage(GPTImageOptions)

	/// The raw model identifier used in the API
	public var identifier: String {
		switch self {
		case .dalle2: return "dall-e-2"
		case .dalle3: return "dall-e-3"
		case .gptImage: return "gpt-image-1"
		}
	}

	/// The options specific to this model
	public var options: ImageGenerationOptions {
		switch self {
		case .dalle2(let options): return options
		case .dalle3(let options): return options
		case .gptImage(let options): return options
		}
	}
}
