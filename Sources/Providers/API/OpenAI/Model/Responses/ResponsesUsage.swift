//
//  ResponsesUsage.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 24.04.25.
//

import Foundation

/// Represents token usage details including input tokens, output tokens, a breakdown of output tokens, and the total tokens used.
public struct ResponsesUsage: Codable, Sendable
{
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
}

/// A detailed breakdown of the input tokens.
public struct InputTokensDetails: Codable, Sendable
{
    /// The number of cached tokens.
    public let cachedTokens: Int
}

/// A detailed breakdown of the output tokens.
public struct OutputTokensDetails: Codable, Sendable
{
    /// The number of reasoning tokens.
    public let reasoningTokens: Int
} 