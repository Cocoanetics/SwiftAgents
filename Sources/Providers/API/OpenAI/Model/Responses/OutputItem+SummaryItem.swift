//
//  OutputItem+SummaryItem.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.04.25.
//

public extension OutputItem {
    /// A summary item in a reasoning output.
    struct SummaryItem: Codable, Sendable {
        /// The type of the summary item.
        public let type: String

        /// The text content of the summary item.
        public let text: String

        public init(type: String, text: String) {
            self.type = type
            self.text = text
        }
    }
}
