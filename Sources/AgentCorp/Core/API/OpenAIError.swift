//
//  APIError.swift
//  AgentCorp
//
//  Created by Oliver Drobnik on 25.01.25.
//

import Foundation

public enum APIError: LocalizedError
{
	case invalidResponse
	case serverError(String)
	case invalidRequest(String)
	case authenticationError(String)
	case quotaError(String)
	case apiError(String)
	case otherError(String, String)
	
	public var errorDescription: String?
	{
		switch self
		{
			case .invalidResponse:
				return "Invalid Response"
				
			case .serverError(_):
				return "Server Error"
				
			case .invalidRequest(let message):
				return "Invalid Request: \(message)"
			
			case .authenticationError(let message):
				return "Authentication Error: \(message)"
				
			case .quotaError(let message):
				return "Quota Error: \(message)"
				
			case .apiError(let message):
				return "API Error: \(message)"
				
			case .otherError(let type, let message):
				return "Unknown Error \(type): \(message)"
		}
	}
	
	public var failureReason: String?
	{
		switch self
		{
			case .invalidResponse:
				return "An invalid response was received"
				
			case .serverError(let message):
				return message
				
			case .invalidRequest(let message):
				return message
			
			case .authenticationError(let message):
				return message
				
			case .quotaError(let message):
				return message
				
			case .apiError(let message):
				return message
				
			case .otherError(_, let message):
				return message
		}
	}
	
	public var type: String
	{
		switch self
		{
			case .invalidResponse:
				return "invalid-response"
			case .serverError(_):
				return "server-error"
			case .invalidRequest(_):
				return "invalid_request_error"
			case .authenticationError(_):
				return "authentication_error"
			case .quotaError(_):
				return "insufficient_quota"
			case .apiError(_):
				return "api_error"
			case .otherError(_, _):
				return "other_error"
		}
	}
}
