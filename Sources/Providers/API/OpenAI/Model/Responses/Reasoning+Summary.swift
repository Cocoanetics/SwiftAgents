//
//  Reasoning+Summary.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.04.25.
//

import Foundation

public extension Reasoning {
    /// The summary style for reasoning models.
    enum Summary: String, Codable, Sendable {
        /// Automatically determine the appropriate summary style.
        case auto

        /// Provide a concise summary of the reasoning process.
        case concise

        /// Provide a detailed summary of the reasoning process.
        case detailed
    }
}
