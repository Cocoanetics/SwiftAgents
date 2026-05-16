//
//  LastError.swift
//
//
//  Created by Oliver Drobnik on 03.05.24.
//

import Foundation

/// Last error details.
public struct LastError: Codable {
	/// Error code, e.g., "server_error" or "rate_limit_exceeded".
	public let code: String

	/// Human-readable description of the error.
	public let message: String
}
