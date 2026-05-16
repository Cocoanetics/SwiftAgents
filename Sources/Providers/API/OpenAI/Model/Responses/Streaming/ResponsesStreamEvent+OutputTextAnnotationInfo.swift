//
//  ResponsesStreamEvent+OutputTextAnnotationInfo.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

extension ResponsesStreamEvent {
	/// Represents a text annotation that was added.
	public struct OutputTextAnnotationInfo: Codable, Sendable
	{
		/// The ID of the output item that the annotation was added to.
		public let itemId: String
		
		/// The index of the output item that the annotation was added to.
		public let outputIndex: Int
		
		/// The index of the content part that the annotation was added to.
		public let contentIndex: Int
		
		/// The index of the annotation that was added.
		public let annotationIndex: Int
		
		/// The annotation that was added.
		public let annotation: Annotation
		
		/// Represents an annotation in the text content.
		public struct Annotation: Codable, Sendable
		{
			/// The type of annotation (e.g., "file_citation").
			public let type: String
			
			/// The index in the text where this annotation applies.
			public let index: Int
			
			/// The ID of the file (for file citations).
			public let fileId: String?
			
			/// The filename (for file citations).
			public let filename: String?
			
			/// The URL being cited (for url_citation type).
			public let url: URL?
			
			/// The title of the cited URL (for url_citation type).
			public let title: String?
		}
	}
} 