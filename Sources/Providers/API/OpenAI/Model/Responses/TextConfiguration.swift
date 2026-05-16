//
//  TextConfiguration.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 24.04.25.
//

import Foundation

/// Configuration options for a text response.
public struct TextConfiguration: Codable, Sendable
{
	public let format: TextFormat
}
