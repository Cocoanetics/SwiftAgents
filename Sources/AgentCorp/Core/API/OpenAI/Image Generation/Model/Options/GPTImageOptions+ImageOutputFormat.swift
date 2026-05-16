//
//  GPTImageOptions+ImageOutputFormat.swift
//
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

extension GPTImageOptions {
	/// The output format for GPT Image
	public enum ImageOutputFormat: String, Codable {
		/// PNG format
		case png = "png"
		/// JPEG format
		case jpeg = "jpeg"
		/// WebP format
		case webp = "webp"
	}
}
