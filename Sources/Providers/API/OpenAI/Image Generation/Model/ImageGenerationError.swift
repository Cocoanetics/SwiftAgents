//
//  ImageGenerationError.swift
//
//
//  Created by Oliver Drobnik on 23.05.24.
//

import Foundation

/// Errors that can occur during image generation
public enum ImageGenerationError: LocalizedError {
    /// Invalid parameter error with a description
    case invalidParameter(String)
    /// Network error with underlying error
    case networkError(Error)
    /// Invalid response error with description
    case invalidResponse(String)
    /// Rate limit exceeded error
    case rateLimitExceeded
    /// Authentication error
    case authenticationError
    /// Server error
    case serverError

    public var errorDescription: String? {
        switch self {
            case let .invalidParameter(message):
                return "Invalid parameter: \(message)"
            case let .networkError(error):
                return "Network error: \(error.localizedDescription)"
            case let .invalidResponse(message):
                return "Invalid response: \(message)"
            case .rateLimitExceeded:
                return "Rate limit exceeded"
            case .authenticationError:
                return "Authentication error"
            case .serverError:
                return "Server error"
        }
    }
}
