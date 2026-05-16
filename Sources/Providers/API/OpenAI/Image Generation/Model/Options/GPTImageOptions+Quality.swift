//
//  GPTImageOptions+Quality.swift
//
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

public extension GPTImageOptions {
    /// Quality options for GPT Image
    enum Quality: String, Codable {
        /// High quality
        case high // Medium quality
        case medium // Low quality
        case low // Auto quality
        case auto
    }
}
