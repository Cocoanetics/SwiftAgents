//
//  GPTImageOptions+ImageOutputFormat.swift
//
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

public extension GPTImageOptions {
    /// The output format for GPT Image
    enum ImageOutputFormat: String, Codable {
        /// PNG format
        case png // JPEG format
        case jpeg // WebP format
        case webp
    }
}
