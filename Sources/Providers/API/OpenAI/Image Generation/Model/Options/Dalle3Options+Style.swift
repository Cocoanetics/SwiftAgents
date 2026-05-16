//
//  Dalle3Options+Style.swift
//  
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

extension Dalle3Options {
	/// The style of the generated images (DALL-E 3 only)
	public enum Style: String, Codable {
		/// Vivid style - hyper-real and dramatic images.
		case vivid		/// Natural style - more natural, less hyper-real looking images.
		case natural	}
}
