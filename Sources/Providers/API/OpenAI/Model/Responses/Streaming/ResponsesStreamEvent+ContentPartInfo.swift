//
//  ResponsesStreamEvent+ContentPartInfo.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

extension ResponsesStreamEvent {
	/// Represents information about a content part in an output item.
	public struct ContentPartInfo: Codable, Sendable
	{
		/// The ID of the output item that the content part was added to.
		public let itemId: String
		
		/// The index of the output item that the content part was added to.
		public let outputIndex: Int
		
		/// The index of the content part.
		public let contentIndex: Int
		
		/// The content part.
		public let part: ContentItem
	}
} 