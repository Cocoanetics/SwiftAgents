//
//  GPTImageOptions+ImageBackground.swift
//  
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

extension GPTImageOptions {
	/// The background style for GPT Image
	public enum ImageBackground: String, Codable {
		/// Transparent background
		case transparent = "transparent"
		/// Opaque background
		case opaque = "opaque"
		/// Auto background
		case auto = "auto"
	}
}
