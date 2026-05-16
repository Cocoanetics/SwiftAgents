//
//  Dalle3Options+Quality.swift
//  
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

extension Dalle3Options {
	/// Quality options for DALL-E 3
	public enum Quality: String, Codable {
		/// Standard quality
		case standard = "standard"
		/// HD quality
		case hd = "hd"
	}
} 