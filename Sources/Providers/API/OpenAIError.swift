//
//  OpenAIError.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.01.25.
//

import Foundation

public enum APIError: LocalizedError {
    case invalidResponse
    case serverError(String)
    case invalidRequest(String)
    case authenticationError(String)
    case quotaError(String)
    case apiError(String)
    case otherError(String, String)

    public var errorDescription: String? {
        switch self {
            case .invalidResponse:
                return "Invalid Response"

            case .serverError:
                return "Server Error"

            case let .invalidRequest(message):
                return "Invalid Request: \(message)"

            case let .authenticationError(message):
                return "Authentication Error: \(message)"

            case let .quotaError(message):
                return "Quota Error: \(message)"

            case let .apiError(message):
                return "API Error: \(message)"

            case let .otherError(type, message):
                return "Unknown Error \(type): \(message)"
        }
    }

    public var failureReason: String? {
        switch self {
            case .invalidResponse:
                return "An invalid response was received"

            case let .serverError(message):
                return message

            case let .invalidRequest(message):
                return message

            case let .authenticationError(message):
                return message

            case let .quotaError(message):
                return message

            case let .apiError(message):
                return message

            case let .otherError(_, message):
                return message
        }
    }

    public var type: String {
        switch self {
            case .invalidResponse:
                return "invalid-response"
            case .serverError:
                return "server-error"
            case .invalidRequest:
                return "invalid_request_error"
            case .authenticationError:
                return "authentication_error"
            case .quotaError:
                return "insufficient_quota"
            case .apiError:
                return "api_error"
            case .otherError:
                return "other_error"
        }
    }
}
