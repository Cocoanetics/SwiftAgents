//
//  Dalle2Options+Size.swift
//
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

public extension Dalle2Options {
    /// Size options for DALL-E 2
    enum Size: String, Codable {
        /// 256x256 pixels
        case small = "256x256"
        /// 512x512 pixels
        case medium = "512x512"
        /// 1024x1024 pixels
        case large = "1024x1024"
    }
}
