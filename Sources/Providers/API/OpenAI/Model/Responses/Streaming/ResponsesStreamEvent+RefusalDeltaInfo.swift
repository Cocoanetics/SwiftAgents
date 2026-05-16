//
//  ResponsesStreamEvent+RefusalDeltaInfo.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

public extension ResponsesStreamEvent {
    /// Represents information about a partial refusal text.
    struct RefusalDeltaInfo: Codable, Sendable {
        /// The ID of the output item that the refusal text is added to.
        public let itemId: String

        /// The index of the output item that the refusal text is added to.
        public let outputIndex: Int

        /// The index of the content part that the refusal text is added to.
        public let contentIndex: Int

        /// The refusal text delta that was added.
        public let delta: String
    }
}
