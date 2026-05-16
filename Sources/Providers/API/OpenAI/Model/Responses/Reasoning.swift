//
//  Reasoning.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 24.04.25.
//

import Foundation

/// Configuration options for reasoning models (o-series models only).
public struct Reasoning: Codable, Sendable {
    /// Constrains effort on reasoning for reasoning models.
    /// Currently supported values are low, medium, and high.
    /// Reducing reasoning effort can result in faster responses and fewer tokens used on reasoning in a response.
    public let effort: Effort?

    /// A summary of the reasoning performed by the model.
    /// This can be useful for debugging and understanding the model's reasoning process.
    /// One of auto, concise, or detailed.
    public var summary: Summary?
}
