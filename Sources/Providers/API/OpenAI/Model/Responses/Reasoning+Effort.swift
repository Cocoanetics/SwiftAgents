//
//  Reasoning+Effort.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.04.25.
//

import Foundation

public extension Reasoning {
    /// The effort level for reasoning models.
    enum Effort: String, Codable, Sendable {
        /// Models that do not expose reasoning effort.
        case none

        /// Minimal reasoning effort.
        case minimal

        /// Low effort reasoning, resulting in faster responses and fewer tokens.
        case low

        /// Medium effort reasoning, balancing speed and thoroughness.
        case medium

        /// High effort reasoning, providing the most thorough analysis.
        case high

        /// Extra-high reasoning effort for the most difficult tasks.
        case xhigh
    }
}
