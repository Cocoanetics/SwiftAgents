//
//  ImageResponseFormat.swift
//  
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

/// The format in which the generated images are returned (non-GPT models)
public enum ImageResponseFormat: String, Codable {
	/// URL format
	case url = "url"
	/// Base64 JSON format
	case base64Json = "b64_json"
}
