//
//  ResponseInputList.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.04.25.
//

import Foundation

/// Represents a list of response items (both input and output).
/// 
/// SeeAlso: [Input Item List API](https://platform.openai.com/docs/api-reference/responses/list)
public struct ResponseInputList: Codable, Sendable {
	/// The type of object, always "list".
	public let object: Response.ListObjectType

	/// A list of response items (both input and output).
	public let data: [ResponseListItem]

	/// The ID of the first item in the list.
	public let firstId: String

	/// The ID of the last item in the list.
	public let lastId: String

	/// Whether there are more items available.
	public let hasMore: Bool

	private enum CodingKeys: String, CodingKey {
		case object
		case data
		case firstId
		case lastId
		case hasMore
	}
}

/// Represents a single item in a response list, which can be either an input or output item.
public enum ResponseListItem: Codable, Sendable {
	/// An input message to the model.
	case inputMessage(InputMessage)

	/// An output message from the model.
	case outputMessage(OutputItem.MessageOutput)

	/// A file search tool call result.
	case fileSearch(OutputItem.FileSearchOutput)

	/// A computer tool call.
	case computerCall(OutputItem.ComputerOutput)

	/// A computer tool call output.
	case computerCallOutput(ComputerCallOutput)

	/// A web search tool call result.
	case webSearch(OutputItem.WebSearchOutput)

	/// A function tool call.
	case functionCall(OutputItem.FunctionCallOutput)

	/// A function tool call output.
	case functionCallOutput(FunctionCallOutput)

	/// A description of the chain of thought used by a reasoning model.
	case reasoning(Reasoning)

	/// An item in the response's input list
	case item(ResponseItem)

	/// A reference to an item in the response's input list
	case itemReference(ResponseItemReference)

	private enum CodingKeys: String, CodingKey {
		case type
		case role
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)

		// First try to decode as a message
		if let type = try? container.decode(String.self, forKey: .type) {
			switch type {
				case "message":
					if let role = try? container.decode(Role.self, forKey: .role) {
						if role == .user || role == .system || role == .developer {
							self = .inputMessage(try InputMessage(from: decoder))
						} else if role == .assistant {
							self = .outputMessage(try OutputItem.MessageOutput(from: decoder))
						} else {
							throw DecodingError.dataCorruptedError(forKey: .role, in: container, debugDescription: "Invalid role: \(role)")
						}
					} else {
						throw DecodingError.keyNotFound(CodingKeys.role, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing role"))
					}

				case "file_search_call":
					self = .fileSearch(try OutputItem.FileSearchOutput(from: decoder))
				case "computer_call":
					self = .computerCall(try OutputItem.ComputerOutput(from: decoder))
				case "computer_call_output":
					self = .computerCallOutput(try ComputerCallOutput(from: decoder))
				case "web_search_call":
					self = .webSearch(try OutputItem.WebSearchOutput(from: decoder))
				case "function_call":
					self = .functionCall(try OutputItem.FunctionCallOutput(from: decoder))
				case "function_call_output":
					self = .functionCallOutput(try FunctionCallOutput(from: decoder))
				case "item_reference":
					self = .itemReference(try ResponseItemReference(from: decoder))
				case "reasoning":
					self = .reasoning(try Reasoning(from: decoder))
				default:
					// If type is not one of the known types, try to decode as an item
					self = .item(try ResponseItem(from: decoder))
			}
		} else {
			// If no type is present, try to decode as an item
			self = .item(try ResponseItem(from: decoder))
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)

		switch self {
			case .inputMessage(let message):
				try container.encode("message", forKey: .type)
				try message.encode(to: encoder)

			case .outputMessage(let message):
				try container.encode("message", forKey: .type)
				try message.encode(to: encoder)

			case .fileSearch(let search):
				try container.encode("file_search_call", forKey: .type)
				try search.encode(to: encoder)

			case .computerCall(let call):
				try container.encode("computer_call", forKey: .type)
				try call.encode(to: encoder)

			case .computerCallOutput(let output):
				try container.encode("computer_call_output", forKey: .type)
				try output.encode(to: encoder)

			case .webSearch(let search):
				try container.encode("web_search_call", forKey: .type)
				try search.encode(to: encoder)

			case .functionCall(let call):
				try container.encode("function_call", forKey: .type)
				try call.encode(to: encoder)

			case .functionCallOutput(let output):
				try container.encode("function_call_output", forKey: .type)
				try output.encode(to: encoder)

			case .reasoning(let reasoning):
				try container.encode("reasoning", forKey: .type)
				try reasoning.encode(to: encoder)

			case .item(let item):
				try item.encode(to: encoder)

			case .itemReference(let reference):
				try container.encode("item_reference", forKey: .type)
				try reference.encode(to: encoder)
		}
	}
}

/// Represents an input message to the model.
public struct InputMessage: Codable, Sendable {
	/// The unique ID of the input message.
	public let id: String

	/// The type of the input message. Always "message".
	public let type: Response.MessageItemType

	/// The role of the input message (user, system, or developer).
	public let role: Role

	/// The status of the input message.
	public let status: ResponseStatus?

	/// The content of the input message.
	public let content: [Response.Input.ContentElement]
}

/// Represents the output of a computer tool call.
public struct ComputerCallOutput: Codable, Sendable {
	/// The ID of the computer tool call that produced the output.
	public let callId: String

	/// The unique ID of the computer call tool output.
	public let id: String

	/// The output of the computer tool call.
	public let output: ComputerScreenshot

	/// The type of the computer tool call output. Always "computer_call_output".
	public let type: Response.ComputerCallOutputType

	/// The safety checks that have been acknowledged.
	public let acknowledgedSafetyChecks: [String]?

	/// The status of the output.
	public let status: ResponseStatus?
}

/// Represents a computer screenshot image.
public struct ComputerScreenshot: Codable, Sendable {
	/// Specifies the event type. For a computer screenshot, this property is always set to computer_screenshot.
	public let type: Response.ComputerScreenshotType

	/// The identifier of an uploaded file that contains the screenshot.
	public let fileId: String

	/// The URL of the screenshot image.
	public let imageUrl: String
}

/// Represents the output of a function tool call.
public struct FunctionCallOutput: Codable, Sendable {
	/// The unique ID of the function tool call generated by the model.
	public let callId: String

	/// The unique ID of the function call tool output. (Optional when sending, set by API when received)
	public let id: String?

	/// A JSON string of the output of the function tool call.
	public let output: String

	/// The type of the function tool call output. Always "function_call_output".
	public let type: Response.FunctionCallOutputType

	/// The status of the output. (Optional when sending, set by API when received)
	public let status: ResponseStatus?

	// Custom initializer to ensure type is set correctly when creating for input
		public init(callId: String, output: String) {
			self.callId = callId
			self.output = output
			self.type = .functionCallOutput
			self.id = nil
			self.status = nil
		}

	// Make Codable synthesize the rest, but ensure type is encoded
	private enum CodingKeys: String, CodingKey {
		case callId
		case id
		case output
		case type
		case status
	}
}

/** An item that can be part of a response's input list */
public struct ResponseItem: Codable, Sendable {
	/** The ID of the item */
	public let id: String

	/** The type of the item */
	public let type: String?

	/** The content of the item */
	public let content: [Response.Input.Element]
}

/** A reference to an item in the response's input list */
public struct ResponseItemReference: Codable, Sendable {
	/** The ID of the referenced item */
	public let id: String

	/** The type of the reference, which is always "item_reference" or null */
	public let type: Response.ItemReferenceType?
}
