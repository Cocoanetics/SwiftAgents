//
//  ResponsesStreamEvent+WebSearchCallInfo.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

public extension ResponsesStreamEvent {
    /// Represents information about a web search call.
    struct WebSearchCallInfo: Codable, Sendable {
        /// The ID of the output item for the web search call.
        public let itemId: String

        /// The index of the output item for the web search call.
        public let outputIndex: Int
    }
}
