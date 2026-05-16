//
//  Message.swift
//
//
//  Created by Oliver Drobnik on 02.05.24.
//

import Foundation

/// Represents a message within a thread on the OpenAI platform.
public struct Message: Codable {
	/// The identifier of the message, which can be referenced in API endpoints.
	public var id: String

	/// The object type, which is always "thread.message".
	var object: String

	/// The Unix timestamp when the message was created.
	public var createdAt: Date

	/// The thread ID to which this message belongs.
	var threadId: String

	/// The status of the message, e.g., in_progress, incomplete, or completed.
	public var status: MessageStatus?

	/// Details about why the message is incomplete, if applicable.
	var incompleteDetails: IncompleteDetails?

	/// The Unix timestamp for when the message was completed, if applicable.
	var completedAt: Date?

	/// The Unix timestamp for when the message was marked as incomplete, if applicable.
	var incompleteAt: Date?

	/// The role of the entity that produced the message, either "user" or "assistant".
	public var role: Role

	/// The content of the message, potentially including text and/or images.
	public var content: [Content]

	/// The ID of the assistant that authored this message, if applicable.
	var assistantId: String?

	/// The ID of the run associated with the creation of this message, if applicable.
	public var runId: String?

	/// A list of attachments linked to the message.
	public var attachments: [Attachment]?

	/// Metadata providing additional information about the message in a key-value format.
	public var metadata: [String: String]
}

public enum Content: Codable {
	case text(TextContent)
	case image(ImageFile)

	enum CodingKeys: String, CodingKey {
		case index
		case type
		case text
		case imageFile
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let type = try container.decode(String.self, forKey: .type)

		switch type {
		case "text":
			let textContent = try container.decode(TextContent.self, forKey: .text)
			self = .text(textContent)
		case "image_file":
			let imageFile = try container.decode(ImageFile.self, forKey: .imageFile)
			self = .image(imageFile)
		default:
			throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown content type: \(type)")
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)

		switch self {
		case .text(let text):
			try container.encode("text", forKey: .type)
			try container.encode(text, forKey: .text)
		case .image(let image):
			try container.encode("image_file", forKey: .type)
			try container.encode(image, forKey: .imageFile)
		}
	}
}

/**
 Represents the status of a file in a vector store.
 */
public enum MessageStatus: String, Codable {
	/// Indicates that the message is incomplete..
	case incomplete = "incomplete"

	/// Indicates that the file is currently in progress.
	case inProgress = "in_progress"

	/// Indicates that the file processing has been completed.
	case completed = "completed"
}

/// Represents an attachment to a message.
public struct Attachment: Codable {
	/// The ID of the file attached to the message.
	public var fileId: String

	/// The tools to which this file is added.
	public var tools: [ToolDescription]
}

public struct ImageFile: Codable {
	public var fileId: String

	enum CodingKeys: String, CodingKey {
		case fileId
	}
}

public struct TextContent: Codable {
	public var value: String
	public var annotations: [Annotation]?

	enum CodingKeys: String, CodingKey {
		case value
		case annotations
	}
}

/// Represents an annotation within the text content of a message.
public struct Annotation: Codable {
	var type: String
	public var text: String
	var startIndex: Int
	var endIndex: Int
	var fileCitation: FileCitation?
	var filePath: FileCitation?

	/// Represents a citation within the message that points to a specific quote from a specific file.
	struct FileCitation: Codable {
		var fileId: String
	}
}

/// used for message creation with minimal data
public struct MessageCreation: Codable {
	/// The role of the entity that produced the message, either "user" or "assistant".
	public var role: Role

	/// The content of the message, potentially including text and/or images.
	public var content: String

	/// A list of attachments linked to the message.
	public var attachments: [Attachment]?

	/// Metadata providing additional information about the message in a key-value format.
	public var metadata: [String: String]?

	public init(role: Role, content: String, attachments: [Attachment]? = nil, metadata: [String: String]? = nil) {
		self.role = role
		self.content = content
		self.attachments = attachments
		self.metadata = metadata
	}
}

/// Represents a delta message within a thread on the OpenAI platform.
public struct ThreadMessageDelta: Codable {
	/// The identifier of the delta message.
	var id: String

	/// The object type, which is always "thread.message.delta".
	var object: String

	/// The delta content of the message.
	var delta: Delta
}

/// Represents the delta content of a message.
public struct Delta: Codable {
	/// The content of the delta message.
	var content: [Content]
}
