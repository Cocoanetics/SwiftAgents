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
		case high		/// Medium quality
		case medium		/// Low quality
		case low		/// Auto quality
		case auto	}
}
