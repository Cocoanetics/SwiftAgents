//
//  Dalle3Options+Size.swift
//  
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

extension Dalle3Options {
	/// Size options for DALL-E 3
	public enum Size: String, Codable {
		/// 1024x1024 pixels
		case large = "1024x1024"
		/// 1792x1024 pixels
		case landscape = "1792x1024"
		/// 1024x1792 pixels
		case portrait = "1024x1792"
	}
}
