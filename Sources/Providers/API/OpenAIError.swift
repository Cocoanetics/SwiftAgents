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

    /// The `previous_response_id` a turn chained from is no longer resolvable
    /// (it was never stored, or its connection-local cache entry was evicted —
    /// the common case under `store=false` / Zero Data Retention). Recover by
    /// starting a fresh chain and resending the full input. `param` is the
    /// offending field, normally `previous_response_id`.
    case previousResponseNotFound(param: String?)

    /// A Responses WebSocket hit the server's 60-minute connection cap. The
    /// transport reconnects and re-issues the turn.
    case connectionLimitReached

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

            case let .previousResponseNotFound(param):
                if let param {
                    return "Previous Response Not Found: \(param)"
                }
                return "Previous Response Not Found"

            case .connectionLimitReached:
                return "Connection Limit Reached"
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

            case .previousResponseNotFound:
                return "The referenced previous_response_id could not be found server-side."

            case .connectionLimitReached:
                return "The WebSocket connection reached its 60-minute limit."
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
            case .previousResponseNotFound:
                return "invalid_request_error"
            case .connectionLimitReached:
                return "invalid_request_error"
        }
    }
}
