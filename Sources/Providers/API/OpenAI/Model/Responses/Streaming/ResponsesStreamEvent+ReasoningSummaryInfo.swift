//
//  ResponsesStreamEvent+ReasoningSummaryInfo.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

extension ResponsesStreamEvent {
	/// Represents information about reasoning summary updates.
	public struct ReasoningSummaryInfo: Codable, Sendable {
		/// The ID of the output item that the reasoning summary is for.
		public let itemId: String
		
		/// The index of the output item that the reasoning summary is for.
		public let outputIndex: Int
		
		/// The index of the summary that is being updated.
		public let summaryIndex: Int
		
		/// The content of the reasoning summary update.
		public let content: Content
		
		/// Represents the content of a reasoning summary update.
		public enum Content: Codable, Sendable {
			/// A delta update to the reasoning summary.
			case delta(String)
			
			/// The complete reasoning summary text.
			case text(String)
			
			public init(from decoder: Decoder) throws {
				let container = try decoder.container(keyedBy: CodingKeys.self)
				
				if let delta = try container.decodeIfPresent(String.self, forKey: .delta) {
					self = .delta(delta)
				} else if let text = try container.decodeIfPresent(String.self, forKey: .text) {
					self = .text(text)
				} else {
					throw DecodingError.dataCorruptedError(
						forKey: .delta,
						in: container,
						debugDescription: "Neither delta nor text found in ReasoningSummaryInfo.Content"
					)
				}
			}
			
			public func encode(to encoder: Encoder) throws {
				var container = encoder.container(keyedBy: CodingKeys.self)
				
				switch self {
				case .delta(let value):
					try container.encode(value, forKey: .delta)
				case .text(let value):
					try container.encode(value, forKey: .text)
				}
			}
			
			private enum CodingKeys: String, CodingKey {
				case delta
				case text
			}
		}
	}
} 