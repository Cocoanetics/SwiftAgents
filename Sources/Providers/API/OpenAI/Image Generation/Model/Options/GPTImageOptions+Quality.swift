//
//  GPTImageOptions+Quality.swift
//  
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

extension GPTImageOptions {
	/// Quality options for GPT Image
	public enum Quality: String, Codable {
		/// High quality
		case high = "high"
		/// Medium quality
		case medium = "medium"
		/// Low quality
		case low = "low"
		/// Auto quality
		case auto = "auto"
	}
}
