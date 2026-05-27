//
//  ProviderError.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 20.05.25.
//

import Foundation
import Providers

/// Errors that can occur when looking up API providers
public enum ProviderError: Error, LocalizedError {
    case unknownProvider(String)
    case missingAPIKey(String)

    public var errorDescription: String? {
        switch self {
            case let .unknownProvider(name):
                return "Unknown provider: \(name)"
            case let .missingAPIKey(provider):
                return "Missing API key for provider: \(provider)"
        }
    }
}
