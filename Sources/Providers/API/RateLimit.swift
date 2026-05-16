//
//  RateLimit.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 24.01.25.
//

import Foundation

/// A struct that holds rate limit information from an API response.
public struct RateLimit {
    /// The maximum number of requests allowed before the rate limit is exhausted.
    public let requestLimit: Int

    /// The maximum number of tokens allowed before the rate limit is exhausted.
    public let tokenLimit: Int

    /// The remaining number of requests allowed before the rate limit is exhausted.
    public let remainingRequests: Int

    /// The remaining number of tokens allowed before the rate limit is exhausted.
    public let remainingTokens: Int

    /// The date when the request-based rate limit will reset.
    public let requestsResetDate: Date

    /// The date when the token-based rate limit will reset.
    public let tokensResetDate: Date

    /// Initializes a `RateLimit` instance by extracting rate limit information from the HTTP response headers.
    ///
    /// - Parameter response: The HTTPURLResponse object containing rate limit headers.
    /// - Returns: An optional `RateLimit` instance if parsing was successful, otherwise `nil`.
    public init?(response: HTTPURLResponse) {
        guard let requestLimitStr = response.value(forHTTPHeaderField: "X-Ratelimit-Limit-Requests"),
            let requestLimit = Int(requestLimitStr),
                let tokenLimitStr = response.value(forHTTPHeaderField: "X-Ratelimit-Limit-Tokens"),
                let tokenLimit = Int(tokenLimitStr),
                let remainingRequestsStr = response.value(forHTTPHeaderField: "X-Ratelimit-Remaining-Requests"),
                let remainingRequests = Int(remainingRequestsStr),
                let remainingTokensStr = response.value(forHTTPHeaderField: "X-Ratelimit-Remaining-Tokens"),
                let remainingTokens = Int(remainingTokensStr),
                let resetRequestsStr = response.value(forHTTPHeaderField: "X-Ratelimit-Reset-Requests"),
                let resetTokensStr = response.value(forHTTPHeaderField: "X-Ratelimit-Reset-Tokens") else {
            return nil
        }

        // Parse reset intervals using the TimeInterval extension
        let requestsResetInterval = TimeInterval(rateLimitString: resetRequestsStr)
        let tokensResetInterval = TimeInterval(rateLimitString: resetTokensStr)

        // Calculate reset dates from the current time
        requestsResetDate = Date().addingTimeInterval(requestsResetInterval)
        tokensResetDate = Date().addingTimeInterval(tokensResetInterval)

        self.requestLimit = requestLimit
        self.tokenLimit = tokenLimit
        self.remainingRequests = remainingRequests
        self.remainingTokens = remainingTokens
    }

    /// Checks if the API request rate limit has been reached.
    ///
    /// - Returns: `true` if no remaining requests are allowed and the reset time has not passed, otherwise `false`.
    public var isRequestRateLimited: Bool {
        return remainingRequests <= 0 && requestsResetDate > Date()
    }

    /// Checks if the API token rate limit has been reached.
    ///
    /// - Returns: `true` if no remaining tokens are allowed and the reset time has not passed, otherwise `false`.
    public var isTokenRateLimited: Bool {
        return remainingTokens <= 0 && tokensResetDate > Date()
    }

    /// Checks if either request or token rate limit has been reached.
    ///
    /// - Returns: `true` if either limit has been reached.
    public var isRateLimited: Bool {
        return isRequestRateLimited || isTokenRateLimited
    }

    /// The furthest reset date, considering both requests and tokens reset times.
    ///
    /// - Returns: The latest reset date.
    public var furthestResetDate: Date {
        return max(requestsResetDate, tokensResetDate)
    }

    /// Waits until the furthest reset date if any rate limit has been reached.
    public func waitForRateLimitReset() async {
        if isRateLimited {
            let waitTime = furthestResetDate.timeIntervalSinceNow
            print("Rate limit exceeded. Waiting for \(waitTime) seconds...")
            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
    }
}
