//
//  OpenAI+ImageGen.swift
//
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

extension OpenAI {
	/**
	 Generates an image based on the provided prompt using the specified model.
	 
	 - Parameters:
	 - prompt: A text description of the desired image(s). Maximum length is 32000 characters for gpt-image-1, 1000 characters for DALL-E 2 and 4000 characters for DALL-E 3.
	 - model: The model to use for image generation with its specific options.
	 
	 - Returns: An array of image data objects containing either URLs or base64-encoded image data.
	 
	 - Throws: An error if the image generation request fails or if the parameters are invalid for the selected model.
	 */
	public func generateImage(
		prompt: String,
		model: ImageGenerationModel
	) async throws -> [ImageData] {
		// Validate prompt length based on model
		let maxPromptLength: Int
		switch model {
			case .dalle2: maxPromptLength = 1000
			case .dalle3: maxPromptLength = 4000
			case .gptImage: maxPromptLength = 32000
		}
		guard prompt.count <= maxPromptLength else {
			throw ImageGenerationError.invalidParameter("Prompt exceeds maximum length of \(maxPromptLength) characters for \(model.identifier)")
		}
		
		// Create the request based on model type
		let request: ImageGenerationRequest
		switch model {
			case .dalle2(let options):
				// DALL-E 2 specific checks
				guard options.count >= 1 && options.count <= 10 else {
					throw ImageGenerationError.invalidParameter("DALL-E 2 requires 1 to 10 images (count=\(options.count))")
				}
				request = ImageGenerationRequest(
					prompt: prompt,
					model: model.identifier,
					n: options.count,
					size: options.size.rawValue,
					responseFormat: options.responseFormat.rawValue,
					user: options.user
				)
				
			case .dalle3(let options):
				// DALL-E 3 specific checks (count=1 is enforced by Dalle3Options)
				request = ImageGenerationRequest(
					prompt: prompt,
					model: model.identifier,
					n: options.count,
					size: options.size.rawValue,
					quality: options.quality.rawValue,
					responseFormat: options.responseFormat.rawValue,
					style: options.style.rawValue,
					user: options.user
				)
				
			case .gptImage(let options):
				// GPT Image specific checks
				guard options.count >= 1 && options.count <= 10 else {
					throw ImageGenerationError.invalidParameter("GPT Image requires 1 to 10 images (count=\(options.count))")
				}
				if let compression = options.outputCompression {
					guard compression >= 0 && compression <= 100 else {
						throw ImageGenerationError.invalidParameter("Output compression must be between 0 and 100")
					}
				}
				request = ImageGenerationRequest(
					prompt: prompt,
					model: model.identifier,
					n: options.count,
					size: options.size.rawValue,
					quality: options.quality.rawValue,
					background: options.background.rawValue,
					moderation: options.moderation.rawValue,
					outputCompression: options.outputCompression,
					outputFormat: options.outputFormat.rawValue,
					user: options.user
				)
		}
		
		// Create the request using the helper function from API
		let urlRequest = try createUrlRequest(httpMethod: "POST", path: "/v1/images/generations", body: request)
		
		// Perform the network request
		do {
			let (data, response) = try await session.data(for: urlRequest)
			
			// Process the response
			let imageResponse: ImageGenerationResponse = try process(data: data, response: response)
			
			return imageResponse.images
		} catch let error as ImageGenerationError {
			throw error
		} catch {
			throw ImageGenerationError.networkError(error)
		}
	}
}
