//
//  TruncationStrategy.swift
//
//
//  Created by Oliver Drobnik on 03.05.24.
//

import Foundation

/// Represents the truncation strategy to use for the thread.
public struct TruncationStrategy: Codable, Sendable
{
	public let type: String
	public let lastMessages: Int?
}
