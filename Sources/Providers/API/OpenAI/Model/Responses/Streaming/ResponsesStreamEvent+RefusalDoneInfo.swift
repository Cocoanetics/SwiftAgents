//
//  ResponsesStreamEvent+RefusalDoneInfo.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

extension ResponsesStreamEvent {
	/// Represents information about finalized refusal text.
	public struct RefusalDoneInfo: Codable, Sendable {
		/// The ID of the output item that the refusal text is finalized for.
		public let itemId: String

		/// The index of the output item that the refusal text is finalized for.
		public let outputIndex: Int

		/// The index of the content part that the refusal text is finalized for.
		public let contentIndex: Int

		/// The complete finalized refusal text.
		public let refusal: String
	}
}
