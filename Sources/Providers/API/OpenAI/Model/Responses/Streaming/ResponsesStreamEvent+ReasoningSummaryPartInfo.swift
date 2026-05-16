//
//  ResponsesStreamEvent+ReasoningSummaryPartInfo.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

public extension ResponsesStreamEvent {
    /// Represents information about a reasoning summary part.
    struct ReasoningSummaryPartInfo: Codable, Sendable {
        /// The ID of the output item this summary part is associated with.
        public let itemId: String

        /// The index of the output item this summary part is associated with.
        public let outputIndex: Int

        /// The index of the summary part within the reasoning summary.
        public let summaryIndex: Int

        /// The summary part.
        public let part: SummaryPart

        /// Represents a summary part in a reasoning output.
        public struct SummaryPart: Codable, Sendable {
            /// The type of the summary part (e.g., "summary_text").
            public let type: String

            /// The text content of the summary part.
            public let text: String
        }
    }
}
