//
//  ResponseStatus.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 24.04.25.
//

import Foundation

/// The status of the response generation.
public enum ResponseStatus: String, Codable, Sendable {
    /// The response has been completed successfully.
    case completed

    /// The response generation failed.
    case failed

    /// The response is still being generated.
    case inProgress = "in_progress"

    /// The response is incomplete.
    case incomplete

    /// The response is queued for background processing.
    case queued

    /// The response was cancelled before completion.
    case cancelled
}
