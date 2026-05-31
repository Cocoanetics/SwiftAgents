//
//  Response+Input+Element.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.04.25.
//

import Foundation
import SwiftMCP

public extension Response.Input {
    /// Represents the different types of elements that can be part of a response input
    enum Element: Codable, Sendable {
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

        /// A reference to a prior image generation call. Replayed as input so a
        /// later turn can edit or refer to that image by its ID alone, without
        /// resending the bytes.
        case imageGenerationCall(OutputItem.ImageGenerationCall)

        /// A server item captured verbatim as raw JSON, replayed byte-for-byte.
        ///
        /// Used for items this SDK doesn't model field-by-field but must forward
        /// unchanged — notably the `compaction` summary from
        /// `/responses/compact`, whose opaque `encrypted_content` must survive
        /// the round-trip intact. Encodes as the wrapped JSON object directly.
        case raw(JSONValue)

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            if let type = try? container.decode(String.self, forKey: .type) {
                switch type {
                    case "message":
                        self = try .message(Message(from: decoder))
                    case "file_search_call":
                        self = try .fileSearch(OutputItem.FileSearchOutput(from: decoder))
                    case "computer_call":
                        self = try .computerCall(OutputItem.ComputerOutput(from: decoder))
                    case "computer_call_output":
                        self = try .computerCallOutput(ComputerCallOutput(from: decoder))
                    case "web_search_call":
                        self = try .webSearch(OutputItem.WebSearchOutput(from: decoder))
                    case "function_call":
                        self = try .functionCall(OutputItem.FunctionCall(from: decoder))
                    case "function_call_output":
                        self = try .functionCallOutput(FunctionCallOutput(from: decoder))
                    case "item_reference":
                        self = try .itemReference(ResponseItemReference(from: decoder))
                    case "reasoning":
                        self = try .reasoning(Reasoning(from: decoder))
                    case "mcp_approval_response":
                        self = try .mcpApprovalResponse(MCPApprovalResponseInput(from: decoder))
                    case "image_generation_call":
                        self = try .imageGenerationCall(OutputItem.ImageGenerationCall(from: decoder))
                    default:
                        // If type is not one of the known types, try to decode as an item
                        self = try .item(ResponseItem(from: decoder))
                }
            } else {
                // If no type is present, try to decode as an item or a message
                do {
                    self = try .message(Message(from: decoder))
                } catch {
                    self = try .item(ResponseItem(from: decoder))
                }
            }
        }

        public func encode(to encoder: Encoder) throws {
            var singleContainer = encoder.singleValueContainer()

            switch self {
                case let .message(message):
                    try singleContainer.encode(message)

                case let .functionCallOutput(output):
                    try singleContainer.encode(output)

                case let .functionCall(call):
                    // `OutputItem.FunctionCall` doesn't include `type` in
                    // its own CodingKeys (it's tagged at the OutputItem
                    // enum level), so we must add the discriminator here
                    // for the Responses API to accept it as a replayed
                    // input item.
                    try singleContainer.encode(FunctionCallWire(
                        id: call.id,
                        callId: call.callId,
                        name: call.name,
                        arguments: call.arguments,
                        status: call.status
                    ))

                case let .mcpApprovalResponse(input):
                    try singleContainer.encode(input)

                case let .applyPatchCallOutput(output):
                    try singleContainer.encode(output)

                case let .imageGenerationCall(call):
                    // Refer to a prior image by ID alone. The Responses API
                    // accepts a bare `{ type, id }` image_generation_call as an
                    // input item and resolves the bytes server-side.
                    try singleContainer.encode(ImageGenerationCallReferenceWire(id: call.id))

                case let .raw(value):
                    // Forward a verbatim server item (e.g. a compaction
                    // summary) byte-for-byte, discriminator and all.
                    try singleContainer.encode(value)

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
                    let context = EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Encoding not implemented for this Response.Input.Element case"
                    )
                    throw EncodingError.invalidValue(self, context)
            }
        }

        /// Wire shape for replaying a prior `function_call` output item as
        /// an `Input.Element`. Tags `type` so the Responses API recognises
        /// the discriminator; everything else mirrors
        /// `OutputItem.FunctionCall`.
        private struct FunctionCallWire: Encodable {
            let id: String
            let callId: String
            let name: String
            let arguments: String
            let status: ResponseStatus?
            let type: String = "function_call"

            private enum CodingKeys: String, CodingKey {
                case id, callId, name, arguments, status, type
            }
        }

        /// Wire shape for replaying a prior image generation call as an input
        /// item by ID. Tags `type` so the Responses API recognises the
        /// discriminator and resolves the referenced image server-side.
        private struct ImageGenerationCallReferenceWire: Encodable {
            let id: String
            let type: String = "image_generation_call"

            private enum CodingKeys: String, CodingKey {
                case id, type
            }
        }

        /// Keep CodingKeys needed for decoding
        private enum CodingKeys: String, CodingKey {
            case type
            case role // Needed to check if it's a message during decoding
        }
    }

    /// Represents a message to be sent as input.
    struct Message: Codable, Sendable {
        public let role: Role
        public let content: [ContentElement]
        public let phase: Response.Phase?

        /// Convenience initializer for simple text content
        public init(role: Role, text: String, phase: Response.Phase? = nil) {
            self.role = role
            content = [.inputText(text)]
            self.phase = phase
        }

        /// Initializer for complex content
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
    enum ContentElement: Codable, Sendable {
        /// User-side text content. Encoded as `{type: "input_text"}` on the
        /// wire. The Responses API rejects this content type when the
        /// enclosing message has `role: assistant` — use `.outputText`
        /// instead for replayed assistant messages.
        case inputText(String)

        /// Assistant-side text content. Encoded as `{type: "output_text"}`.
        /// Used when feeding a prior assistant turn back into the model as
        /// input on a stateless or session-driven turn.
        case outputText(String)

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
                case "output_text":
                    let text = try container.decode(String.self, forKey: .text)
                    self = .outputText(text)
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
                case let .inputText(text):
                    try container.encode("input_text", forKey: .type)
                    try container.encode(text, forKey: .text)
                case let .outputText(text):
                    try container.encode("output_text", forKey: .type)
                    try container.encode(text, forKey: .text)
                case let .inputImage(url):
                    try container.encode("input_image", forKey: .type)
                    // Only encode the imageURL if the url is not nil
                    if let url {
                        try container.encode(url.absoluteString, forKey: .imageURL)
                    }
                // If url is nil, the imageURL key will be omitted, which matches the API behavior for sending nulls
                case let .inputImageFileID(fileID):
                    try container.encode("input_image", forKey: .type)
                    try container.encode(fileID, forKey: .fileID)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "imageUrl"
            case fileID = "file_id"
        }
    }

    /// Represents an MCP approval response input item.
    struct MCPApprovalResponseInput: Codable, Sendable {
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

        public init(approve: Bool, approvalRequestId: String) {
            self.approve = approve
            self.approvalRequestId = approvalRequestId
        }
    }
}
