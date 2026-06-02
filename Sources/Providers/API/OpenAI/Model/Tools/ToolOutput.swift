//
//  ToolOutput.swift
//
//
//  Created by Oliver Drobnik on 03.05.24.
//

import Foundation

/// Represents the output of a tool call.
public struct ToolOutput: Codable, Sendable {
    /// The ID of the tool call.
    public let toolCallId: String

    /// The output of the tool call.
    public let output: String
}
