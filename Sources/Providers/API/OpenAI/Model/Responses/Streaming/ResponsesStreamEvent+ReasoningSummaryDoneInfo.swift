//
//  ResponsesStreamEvent+ReasoningSummaryDoneInfo.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

extension ResponsesStreamEvent {
    /// Represents information about a completed reasoning summary.
    public struct ReasoningSummaryDoneInfo: Codable, Sendable {
        /// The ID of the output item that the reasoning summary is for.
        public let itemId: String

        /// The index of the output item that the reasoning summary is for.
        public let outputIndex: Int

        /// The index of the summary that is being completed.
        public let summaryIndex: Int
    }
}
