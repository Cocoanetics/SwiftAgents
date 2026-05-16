//
//  ResponsesStreamEvent+OutputTextDeltaInfo.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

public extension ResponsesStreamEvent {
    /// Represents an additional text delta in a content part.
    struct OutputTextDeltaInfo: Codable, Sendable {
        /// The ID of the output item that the text delta was added to.
        public let itemId: String

        /// The index of the output item that the text delta was added to.
        public let outputIndex: Int

        /// The index of the content part that the text delta was added to.
        public let contentIndex: Int

        /// The text delta that was added.
        public let delta: String
    }
}
