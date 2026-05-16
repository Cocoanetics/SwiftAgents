//
//  ResponsesStreamEvent+ReasoningSummaryErrorInfo.swift
//  AgentCorp
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

extension ResponsesStreamEvent {
    /// Represents information about an error in a reasoning summary.
    public struct ReasoningSummaryErrorInfo: Codable, Sendable
    {
        /// The ID of the output item that the reasoning summary is for.
        public let itemId: String
        
        /// The index of the output item that the reasoning summary is for.
        public let outputIndex: Int
        
        /// The index of the summary that encountered an error.
        public let summaryIndex: Int
        
        /// The error message.
        public let message: String
    }
} 