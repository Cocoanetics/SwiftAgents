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
    /// An error reported by the Images API, with its `x-request-id`
    case api(ImageAPIError)

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
            case let .api(error):
                return error.description
        }
    }
}

/// An error response from the Images API.
public struct ImageAPIError: Sendable, Equatable, CustomStringConvertible {
    public var statusCode: Int
    public var message: String
    public var type: String?
    public var code: String?
    public var param: String?
    /// The `x-request-id` response header, for support requests.
    public var requestID: String?

    public init(
        statusCode: Int,
        message: String,
        type: String? = nil,
        code: String? = nil,
        param: String? = nil,
        requestID: String? = nil
    ) {
        self.statusCode = statusCode
        self.message = message
        self.type = type
        self.code = code
        self.param = param
        self.requestID = requestID
    }

    public var description: String {
        var details = ["HTTP \(statusCode)"]
        if let type { details.append(type) }
        if let code { details.append(code) }
        if let requestID { details.append("request id \(requestID)") }
        return "OpenAI Images API error (\(details.joined(separator: ", "))): \(message)"
    }
}
