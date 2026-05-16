//
//  ResponsesStreamEvent+WebSearchCallInfo.swift
//  AgentCorp
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

extension ResponsesStreamEvent
{
	/// Represents information about a web search call.
	public struct WebSearchCallInfo: Codable, Sendable
	{
		/// The ID of the output item for the web search call.
		public let itemId: String
		
		/// The index of the output item for the web search call.
		public let outputIndex: Int
	}
}
