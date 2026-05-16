//
//  ResponsesStreamEvent+OutputTextDoneInfo.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

extension ResponsesStreamEvent {
	/// Represents information about finalized text content.
	public struct OutputTextDoneInfo: Codable, Sendable
	{
		/// The ID of the output item that the text content is finalized for.
		public let itemId: String
		
		/// The index of the output item that the text content is finalized for.
		public let outputIndex: Int
		
		/// The index of the content part that the text content is finalized for.
		public let contentIndex: Int
		
		/// The complete finalized text content.
		public let text: String
	}
} 