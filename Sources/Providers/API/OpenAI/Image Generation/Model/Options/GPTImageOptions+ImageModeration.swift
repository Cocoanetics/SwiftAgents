//
//  GPTImageOptions+ImageModeration.swift
//
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

public extension GPTImageOptions {
    /// The moderation level for GPT Image
    enum ImageModeration: String, Codable {
        /// Low moderation
        case low // Auto moderation
        case auto
    }
}
