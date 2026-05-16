//
//  ResponsesStreamEvent+FunctionCallArgumentsDoneInfo.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

public extension ResponsesStreamEvent {
    /// Represents information about finalized function-call arguments.
    struct FunctionCallArgumentsDoneInfo: Codable, Sendable {
        /// The ID of the output item that the function-call arguments are finalized for.
        public let itemId: String

        /// The index of the output item that the function-call arguments are finalized for.
        public let outputIndex: Int

        /// The complete finalized function-call arguments as a JSON string.
        public let arguments: String
    }
}
