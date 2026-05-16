//
//  Dalle3Options+Quality.swift
//
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

public extension Dalle3Options {
    /// Quality options for DALL-E 3
    enum Quality: String, Codable {
        /// Standard quality
        case standard
        // HD quality. Name mirrors OpenAI DALL·E 3 API value.
        // swiftlint:disable:next identifier_name
        case hd
    }
}
