//
//  ResponsesStreamEvent+OutputItemInfo.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

public extension ResponsesStreamEvent {
    /// Represents information about an output item in a response.
    struct OutputItemInfo: Codable, Sendable {
        /// The index of the output item.
        public let outputIndex: Int

        /// The output item.
        public let item: OutputItem
    }
}
