//
//  ResponsesStreamEvent+FunctionCallArgumentsDeltaInfo.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

public extension ResponsesStreamEvent {
    /// Represents information about a partial function-call arguments delta.
    struct FunctionCallArgumentsDeltaInfo: Codable, Sendable {
        /// The ID of the output item that the function-call arguments delta is added to.
        public let itemId: String

        /// The index of the output item that the function-call arguments delta is added to.
        public let outputIndex: Int

        /// The function-call arguments delta that was added.
        public let delta: String
    }
}
