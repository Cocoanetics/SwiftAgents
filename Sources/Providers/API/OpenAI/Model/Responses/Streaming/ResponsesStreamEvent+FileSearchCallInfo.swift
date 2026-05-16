//
//  ResponsesStreamEvent+FileSearchCallInfo.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

extension ResponsesStreamEvent
{
	/// Represents information about a file search call.
	public struct FileSearchCallInfo: Codable, Sendable
	{
		/// The ID of the output item for the file search call.
		public let itemId: String
		
		/// The index of the output item for the file search call.
		public let outputIndex: Int
	}
}
