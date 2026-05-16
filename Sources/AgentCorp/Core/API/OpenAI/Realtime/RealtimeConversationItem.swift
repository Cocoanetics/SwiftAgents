import Foundation
import SwiftMCP

public enum RealtimeConversationItem: Codable, Sendable {
	case message(Message)
	case functionCall(OutputItem.FunctionCall)
	case functionCallOutput(FunctionCallOutput)
	case mcpListTools(OutputItem.MCPListToolsOutput)
	case mcpApprovalRequest(OutputItem.MCPApprovalRequestOutput)
	case mcpCall(OutputItem.MCPCallOutput)
	case unknown(Unknown)

	private enum CodingKeys: String, CodingKey {
		case type
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let type = try container.decode(String.self, forKey: .type)

		switch type {
			case "message":
				self = .message(try Message(from: decoder))
			case "function_call":
				self = .functionCall(try OutputItem.FunctionCall(from: decoder))
			case "function_call_output":
				self = .functionCallOutput(try FunctionCallOutput(from: decoder))
			case "mcp_list_tools":
				self = .mcpListTools(try OutputItem.MCPListToolsOutput(from: decoder))
			case "mcp_approval_request":
				self = .mcpApprovalRequest(try OutputItem.MCPApprovalRequestOutput(from: decoder))
			case "mcp_call":
				self = .mcpCall(try OutputItem.MCPCallOutput(from: decoder))
			default:
				self = .unknown(try Unknown(from: decoder))
		}
	}

	public func encode(to encoder: Encoder) throws {
		switch self {
			case .message(let message):
				try message.encode(to: encoder)
			case .functionCall(let functionCall):
				var container = encoder.container(keyedBy: CodingKeys.self)
				try container.encode("function_call", forKey: .type)
				try functionCall.encode(to: encoder)
			case .functionCallOutput(let functionCallOutput):
				try functionCallOutput.encode(to: encoder)
			case .mcpListTools(let output):
				try output.encode(to: encoder)
			case .mcpApprovalRequest(let output):
				try output.encode(to: encoder)
			case .mcpCall(let output):
				try output.encode(to: encoder)
			case .unknown(let unknown):
				try unknown.encode(to: encoder)
		}
	}

	public var id: String? {
		switch self {
			case .message(let message):
				return message.id
			case .functionCall(let functionCall):
				return functionCall.id
			case .functionCallOutput(let output):
				return output.id
			case .mcpListTools(let output):
				return output.id
			case .mcpApprovalRequest(let output):
				return output.id
			case .mcpCall(let output):
				return output.id
			case .unknown(let unknown):
				return unknown.id
		}
	}

	public struct Unknown: Codable, Sendable {
		public let id: String?
		public let type: String
		public let raw: [String: JSONValue]?

		private enum CodingKeys: String, CodingKey {
			case id
			case type
		}

		public init(id: String? = nil, type: String, raw: [String: JSONValue]? = nil) {
			self.id = id
			self.type = type
			self.raw = raw
		}

		public init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			id = try container.decodeIfPresent(String.self, forKey: .id)
			type = try container.decode(String.self, forKey: .type)
			raw = try? decoder.singleValueContainer().decode([String: JSONValue].self)
		}

		public func encode(to encoder: Encoder) throws {
			if let raw {
				var container = encoder.singleValueContainer()
				try container.encode(raw)
				return
			}

			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encodeIfPresent(id, forKey: .id)
			try container.encode(type, forKey: .type)
		}
	}

	public struct Message: Codable, Sendable {
		public enum Content: Codable, Sendable {
			case inputText(InputText)
			case inputAudio(Audio)
			case outputText(OutputText)
			case outputAudio(Audio)

			private enum CodingKeys: String, CodingKey {
				case type
				case text
				case audio
				case transcript
				case annotations
				case logprobs
			}

			public init(from decoder: Decoder) throws {
				let container = try decoder.container(keyedBy: CodingKeys.self)
				let type = try container.decode(String.self, forKey: .type)

				switch type {
					case "input_text":
						self = .inputText(try InputText(from: decoder))
					case "input_audio":
						self = .inputAudio(try Audio(from: decoder))
					case "output_text":
						self = .outputText(try OutputText(from: decoder))
					case "output_audio":
						self = .outputAudio(try Audio(from: decoder))
					default:
						throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported realtime message content type: \(type)")
				}
			}

			public func encode(to encoder: Encoder) throws {
				switch self {
					case .inputText(let inputText):
						try inputText.encode(to: encoder)
					case .inputAudio(let audio):
						try audio.encode(as: "input_audio", to: encoder)
					case .outputText(let outputText):
						try outputText.encode(to: encoder)
					case .outputAudio(let audio):
						try audio.encode(as: "output_audio", to: encoder)
				}
			}
		}

		public struct InputText: Codable, Sendable {
			public var type = "input_text"
			public var text: String

			public init(text: String) {
				self.text = text
			}
		}

		public struct Audio: Codable, Sendable {
			public var audio: Data?
			public var transcript: String?
			public var audioEndMilliseconds: Int?

			private enum CodingKeys: String, CodingKey {
				case type
				case audio
				case transcript
			}

			public init(audio: Data? = nil, transcript: String? = nil, audioEndMilliseconds: Int? = nil) {
				self.audio = audio
				self.transcript = transcript
				self.audioEndMilliseconds = audioEndMilliseconds
			}

			public init(from decoder: Decoder) throws {
				let container = try decoder.container(keyedBy: CodingKeys.self)
				audio = try container.decodeIfPresent(Data.self, forKey: .audio)
				transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
				audioEndMilliseconds = nil
			}

			public func encode(to encoder: Encoder) throws {
				try encode(as: "input_audio", to: encoder)
			}

			public func encode(as type: String, to encoder: Encoder) throws {
				var container = encoder.container(keyedBy: CodingKeys.self)
				try container.encode(type, forKey: .type)
				try container.encodeIfPresent(audio, forKey: .audio)
				try container.encodeIfPresent(transcript, forKey: .transcript)
			}
		}

		public struct OutputText: Codable, Sendable {
			public var type = "output_text"
			public var text: String
			public var annotations: [OutputItem.MessageOutput.Annotation]
			public var logprobs: [ContentItem.OutputText.Logprob]?

			private enum CodingKeys: String, CodingKey {
				case type
				case text
				case annotations
				case logprobs
			}

			public init(
				text: String,
				annotations: [OutputItem.MessageOutput.Annotation] = [],
				logprobs: [ContentItem.OutputText.Logprob]? = nil
			) {
				self.text = text
				self.annotations = annotations
				self.logprobs = logprobs
			}

			public init(from decoder: Decoder) throws {
				let container = try decoder.container(keyedBy: CodingKeys.self)
				type = try container.decodeIfPresent(String.self, forKey: .type) ?? "output_text"
				text = try container.decode(String.self, forKey: .text)
				annotations = try container.decodeIfPresent([OutputItem.MessageOutput.Annotation].self, forKey: .annotations) ?? []
				logprobs = try container.decodeIfPresent([ContentItem.OutputText.Logprob].self, forKey: .logprobs)
			}
		}

		public var id: String?
		public var type: String
		public var status: ResponseStatus?
		public var role: Role
		public var content: [Content]

		public init(
			id: String? = nil,
			type: String = "message",
			status: ResponseStatus? = nil,
			role: Role,
			content: [Content]
		) {
			self.id = id
			self.type = type
			self.status = status
			self.role = role
			self.content = content
		}

		public static func user(text: String) -> Message {
			Message(role: .user, content: [.inputText(.init(text: text))])
		}

		public static func system(text: String) -> Message {
			Message(role: .system, content: [.inputText(.init(text: text))])
		}
	}
}
