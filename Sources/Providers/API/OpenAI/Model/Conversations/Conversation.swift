//
//  Conversation.swift
//
//
//  Created by Oliver Drobnik on 14.04.26.
//

import Foundation

/// Represents a conversation object from the OpenAI Conversations API.
/// Conversations persist state as a long-running object with its own durable identifier,
/// and can be used across sessions, devices, or jobs.
public struct Conversation: Codable, Sendable {
    /// The unique ID of the conversation.
    public var id: String

    /// The object type, always "conversation".
    public var object: String

    /// The time at which the conversation was created, measured in seconds since the Unix epoch.
    public var createdAt: Date

    /// A set of up to 16 key-value pairs for storing additional information.
    /// Keys can be a maximum of 64 characters long and values can be a maximum of 512 characters long.
    public var metadata: [String: String]?
}

/// Represents the parameters for creating or updating a conversation.
struct ConversationOptionals: Codable {
    /// Optional items to include in the conversation context (up to 20 items at a time).
    var items: [Response.Input.Element]?

    /// A set of up to 16 key-value pairs for storing additional information.
    var metadata: [String: String]?
}

/// Status returned from deleting a conversation.
public struct ConversationDeletedResource: Codable, Sendable {
    /// The unique ID of the deleted conversation.
    public let id: String

    /// The object type, always "conversation.deleted".
    public let object: String

    /// Whether the conversation was successfully deleted.
    public let deleted: Bool
}

/// Represents a list of conversation items returned from the API.
public struct ConversationItemList: Codable {
    /// The type of object returned, always "list".
    public let object: String

    /// The list of conversation items.
    public let data: [ConversationItem]

    /// The ID of the first item in the list.
    public let firstId: String?

    /// The ID of the last item in the list.
    public let lastId: String?

    /// Whether there are more items available.
    public let hasMore: Bool
}

/// Represents an item within a conversation.
/// Items can be messages, function calls, function call outputs, and other types.
public struct ConversationItem: Codable, Sendable {
    /// The unique ID of the item.
    public var id: String

    /// The type of the item (e.g., "message", "function_call", "function_call_output").
    public var type: String

    /// The status of the item (e.g., "in_progress", "completed", "incomplete").
    public var status: String?

    /// The role of the item (e.g., "user", "assistant", "system", "developer").
    public var role: String?

    /// The content of the item, if applicable.
    public var content: [ConversationItemContent]?
}

/// Represents a content element within a conversation item.
public struct ConversationItemContent: Codable, Sendable {
    /// The type of content (e.g., "input_text", "output_text", "refusal", "input_image", "input_audio").
    public var type: String

    /// The text content, if applicable.
    public var text: String?

    /// Annotations on the content, if applicable.
    public var annotations: [ConversationItemAnnotation]?
}

/// Represents an annotation on conversation item content.
public struct ConversationItemAnnotation: Codable, Sendable {
    /// The type of annotation.
    public var type: String

    /// The start index of the annotation.
    public var startIndex: Int?

    /// The end index of the annotation.
    public var endIndex: Int?
}
