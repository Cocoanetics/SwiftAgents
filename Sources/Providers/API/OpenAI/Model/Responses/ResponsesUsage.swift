//
//  ResponsesUsage.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 24.04.25.
//

import Foundation

/// Represents token usage details including input tokens, output tokens, a breakdown of output tokens, and the total
/// tokens used.
public struct ResponsesUsage: Codable, Sendable {
    /// The number of input tokens.
    public let inputTokens: Int

    /// A detailed breakdown of the input tokens.
    public let inputTokensDetails: InputTokensDetails

    /// The number of output tokens.
    public let outputTokens: Int

    /// A detailed breakdown of the output tokens.
    public let outputTokensDetails: OutputTokensDetails

    /// The total number of tokens used.
    public let totalTokens: Int

    public init(
        inputTokens: Int,
        inputTokensDetails: InputTokensDetails,
        outputTokens: Int,
        outputTokensDetails: OutputTokensDetails,
        totalTokens: Int
    ) {
        self.inputTokens = inputTokens
        self.inputTokensDetails = inputTokensDetails
        self.outputTokens = outputTokens
        self.outputTokensDetails = outputTokensDetails
        self.totalTokens = totalTokens
    }
}

/// A detailed breakdown of the input tokens.
public struct InputTokensDetails: Codable, Sendable {
    /// The number of cached tokens.
    public let cachedTokens: Int

    public init(cachedTokens: Int) {
        self.cachedTokens = cachedTokens
    }
}

/// A detailed breakdown of the output tokens.
public struct OutputTokensDetails: Codable, Sendable {
    /// The number of reasoning tokens.
    public let reasoningTokens: Int

    public init(reasoningTokens: Int) {
        self.reasoningTokens = reasoningTokens
    }
}
