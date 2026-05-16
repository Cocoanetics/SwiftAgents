//
//  GPTImageOptions+Size.swift
//
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

public extension GPTImageOptions {
    /// Size options for GPT Image
    enum Size: String, Codable {
        /// 1024x1024 pixels
        case large = "1024x1024"
        /// 1536x1024 pixels
        case landscape = "1536x1024"
        /// Auto size
        case auto
    }
}
