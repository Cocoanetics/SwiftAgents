//
//  ResponseInputElement.swift
//  AgentCorp
//
//  Created by Oliver Drobnik on 25.04.25.
//

import Foundation

extension Response.Input {
	
	/// Represents the different types of elements that can be part of a response input
	public enum Element: Codable, Sendable
	{
		/// A message (user, assistant, system, or tool).
		case message(Message)
		
		/// A file search tool call result.
		case fileSearch(OutputItem.FileSearchOutput)
		
		/// A computer tool call.
		case computerCall(OutputItem.ComputerOutput)
		
		/// A computer tool call output.
		case computerCallOutput(ComputerCallOutput)
		
		/// A web search tool call result.
		case webSearch(OutputItem.WebSearchOutput)
		
		/// A function tool call.
		case functionCall(OutputItem.FunctionCall)
		
		/// A function tool call output.
		case functionCallOutput(FunctionCallOutput)
		
		/// A description of the chain of thought used by a reasoning model.
		case reasoning(Reasoning)
		
		/// An item in the response's input list.
		case item(ResponseItem)
		
		/// A reference to an item in the response's input list.
		case itemReference(ResponseItemReference)
		
		/// An MCP approval response.
		case mcpApprovalResponse(MCPApprovalResponseInput)

		/// An apply_patch tool call output.
		case applyPatchCallOutput(ApplyPatchCallOutputResult)
		
		public init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			
			if let type = try? container.decode(String.self, forKey: .type)
			{
				switch type
				{
					case "message":
						self = .message(try Message(from: decoder))
						
					case "file_search_call":
						self = .fileSearch(try OutputItem.FileSearchOutput(from: decoder))
					case "computer_call":
						self = .computerCall(try OutputItem.ComputerOutput(from: decoder))
					case "computer_call_output":
						self = .computerCallOutput(try ComputerCallOutput(from: decoder))
					case "web_search_call":
						self = .webSearch(try OutputItem.WebSearchOutput(from: decoder))
					case "function_call":
						self = .functionCall(try OutputItem.FunctionCall(from: decoder))
					case "function_call_output":
						self = .functionCallOutput(try FunctionCallOutput(from: decoder))
					case "item_reference":
						self = .itemReference(try ResponseItemReference(from: decoder))
					case "reasoning":
						self = .reasoning(try Reasoning(from: decoder))
					case "mcp_approval_response":
						self = .mcpApprovalResponse(try MCPApprovalResponseInput(from: decoder))
					default:
						// If type is not one of the known types, try to decode as an item
						self = .item(try ResponseItem(from: decoder))
				}
			}
			else
			{
				// If no type is present, try to decode as an item or a message
				do {
					self = .message(try Message(from: decoder))
				} catch {
					self = .item(try ResponseItem(from: decoder))
				}
			}
		}
		
		public func encode(to encoder: Encoder) throws {
			var singleContainer = encoder.singleValueContainer()
			
			switch self
			{
				case .message(let message):
					try singleContainer.encode(message)
					
				case .functionCallOutput(let output):
					try singleContainer.encode(output)
					
				case .mcpApprovalResponse(let input):
					try singleContainer.encode(input)

				case .applyPatchCallOutput(let output):
					try singleContainer.encode(output)

				// --- Encoding for other types if needed for input ---
				// Add encoding logic here if fileSearch, computerCall, etc.,
				// need to be sent in the input array.
				// If they are only ever *received* or *listed*,
				// the encoding logic might not be necessary here.
				// Example:
				// case .computerCallOutput(let output):
				//    try singleContainer.encode(output)
					
				default:
					// Handle encoding for other cases or throw an error if they aren't meant to be encoded here
					let context = EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Encoding not implemented for this Response.Input.Element case")
					throw EncodingError.invalidValue(self, context)
			}
		}
		
		// Keep CodingKeys needed for decoding
		private enum CodingKeys: String, CodingKey
		{
			case type
			case role // Needed to check if it's a message during decoding
		}
	}
	
	/// Represents a message to be sent as input.
	public struct Message: Codable, Sendable {
		public let role: Role
		public let content: [ContentElement]
		public let phase: Response.Phase?
		
		// Convenience initializer for simple text content
		public init(role: Role, text: String, phase: Response.Phase? = nil) {
			self.role = role
			self.content = [.inputText(text)]
			self.phase = phase
		}
		
		// Initializer for complex content
		public init(role: Role, content: [ContentElement], phase: Response.Phase? = nil) {
			self.role = role
			self.content = content
			self.phase = phase
		}

		public init(role: String, text: String, phase: Response.Phase? = nil) {
			guard let role = Role(rawValue: role) else {
				preconditionFailure("Unsupported response message role: \(role)")
			}

			self.init(role: role, text: text, phase: phase)
		}

		public init(role: String, content: [ContentElement], phase: Response.Phase? = nil) {
			guard let role = Role(rawValue: role) else {
				preconditionFailure("Unsupported response message role: \(role)")
			}

			self.init(role: role, content: content, phase: phase)
		}
	}
	
	/// Represents the different types of content elements in a message
	public enum ContentElement: Codable, Sendable
	{
		/// Text content
		case inputText(String)
		
		/// Image URL content
		case inputImage(URL?)
		
		/// Image uploaded to OpenAI referenced by file identifier
		case inputImageFileID(String)
		
		public init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			let type = try container.decode(String.self, forKey: .type)
			
			switch type {
				case "input_text":
					let text = try container.decode(String.self, forKey: .text)
					self = .inputText(text)
				case "input_image":
					if let fileID = try container.decodeIfPresent(String.self, forKey: .fileID) {
						self = .inputImageFileID(fileID)
					} else if let imageURLString = try container.decodeIfPresent(String.self, forKey: .imageURL) {
						guard let url = URL(string: imageURLString) else {
							throw DecodingError.dataCorruptedError(
								forKey: .imageURL,
								in: container,
								debugDescription: "Invalid URL string: \(imageURLString)"
							)
						}
						self = .inputImage(url)
					} else {
						self = .inputImage(nil)
					}
				default:
					throw DecodingError.dataCorruptedError(
						forKey: .type,
						in: container,
						debugDescription: "Invalid content element type: \(type)"
					)
			}
		}
		
		public func encode(to encoder: Encoder) throws {
			var container = encoder.container(keyedBy: CodingKeys.self)
			
			switch self {
				case .inputText(let text):
					try container.encode("input_text", forKey: .type)
					try container.encode(text, forKey: .text)
				case .inputImage(let url):
					try container.encode("input_image", forKey: .type)
					// Only encode the imageURL if the url is not nil
					if let url = url {
						try container.encode(url.absoluteString, forKey: .imageURL)
					}
					// If url is nil, the imageURL key will be omitted, which matches the API behavior for sending nulls
				case .inputImageFileID(let fileID):
					try container.encode("input_image", forKey: .type)
					try container.encode(fileID, forKey: .fileID)
			}
		}
		
		private enum CodingKeys: String, CodingKey
		{
			case type
			case text
			case imageURL = "imageUrl"
			case fileID = "file_id"
		}
	}
	
	/// Represents an MCP approval response input item.
	public struct MCPApprovalResponseInput: Codable, Sendable {
		/// The type of the input item, always "mcp_approval_response".
		public let type: String = "mcp_approval_response"
		/// Whether the MCP tool call was approved.
		public let approve: Bool
		/// The ID of the mcp_approval_request output item this is responding to.
		public let approvalRequestId: String

		private enum CodingKeys: String, CodingKey {
			case type
			case approve
			case approvalRequestId = "approval_request_id"
		}
	}
}
