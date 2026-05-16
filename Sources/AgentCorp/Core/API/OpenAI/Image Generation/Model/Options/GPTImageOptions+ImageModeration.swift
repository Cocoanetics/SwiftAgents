//
//  GPTImageOptions+ImageModeration.swift
//
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

extension GPTImageOptions {
	/// The moderation level for GPT Image
	public enum ImageModeration: String, Codable {
		/// Low moderation
		case low = "low"
		/// Auto moderation
		case auto = "auto"
	}
}
