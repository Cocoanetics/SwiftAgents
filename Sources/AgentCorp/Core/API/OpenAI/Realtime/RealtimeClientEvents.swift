import Foundation

public struct RealtimeSessionUpdateEvent: Encodable, Sendable {
	public let type = "session.update"
	public let eventId: String?
	public let session: RealtimeSessionConfiguration

	public init(eventId: String? = nil, session: RealtimeSessionConfiguration) {
		self.eventId = eventId
		self.session = session
	}
}

public struct RealtimeResponseCreate: Encodable, Sendable {
	public var instructions: String?
	public var conversation: String?
	public var input: [RealtimeConversationItem]?
	public var metadata: [String: String]?
	public var maxOutputTokens: RealtimeSessionConfiguration.MaxOutputTokens?
	public var outputModalities: [RealtimeSessionConfiguration.OutputModality]?
	public var toolChoice: ToolChoice?
	public var tools: [Tool]?

	public init(
		instructions: String? = nil,
		conversation: String? = nil,
		input: [RealtimeConversationItem]? = nil,
		metadata: [String: String]? = nil,
		maxOutputTokens: RealtimeSessionConfiguration.MaxOutputTokens? = nil,
		outputModalities: [RealtimeSessionConfiguration.OutputModality]? = nil,
		toolChoice: ToolChoice? = nil,
		tools: [Tool]? = nil
	) {
		self.instructions = instructions
		self.conversation = conversation
		self.input = input
		self.metadata = metadata
		self.maxOutputTokens = maxOutputTokens
		self.outputModalities = outputModalities
		self.toolChoice = toolChoice
		self.tools = tools
	}

	public var isEmpty: Bool {
		instructions == nil &&
		conversation == nil &&
		input == nil &&
		metadata == nil &&
		maxOutputTokens == nil &&
		outputModalities == nil &&
		toolChoice == nil &&
		tools == nil
	}
}

public struct RealtimeResponseCreateEvent: Encodable, Sendable {
	public let type = "response.create"
	public let eventId: String?
	public let response: RealtimeResponseCreate?

	public init(eventId: String? = nil, response: RealtimeResponseCreate? = nil) {
		self.eventId = eventId
		self.response = response?.isEmpty == false ? response : nil
	}
}

public struct RealtimeResponseCancelEvent: Encodable, Sendable {
	public let type = "response.cancel"
	public let eventId: String?

	public init(eventId: String? = nil) {
		self.eventId = eventId
	}
}

public struct RealtimeConversationItemCreateEvent: Encodable, Sendable {
	public let type = "conversation.item.create"
	public let eventId: String?
	public let previousItemId: String?
	public let item: RealtimeConversationItem

	public init(eventId: String? = nil, previousItemId: String? = nil, item: RealtimeConversationItem) {
		self.eventId = eventId
		self.previousItemId = previousItemId
		self.item = item
	}
}

public struct RealtimeConversationItemTruncateEvent: Encodable, Sendable {
	public let type = "conversation.item.truncate"
	public let eventId: String?
	public let itemId: String
	public let contentIndex: Int
	public let audioEndMs: Int

	public init(eventId: String? = nil, itemId: String, contentIndex: Int = 0, audioEndMs: Int) {
		self.eventId = eventId
		self.itemId = itemId
		self.contentIndex = contentIndex
		self.audioEndMs = audioEndMs
	}
}

public struct RealtimeInputAudioBufferAppendEvent: Encodable, Sendable {
	public let type = "input_audio_buffer.append"
	public let eventId: String?
	public let audio: String

	public init(eventId: String? = nil, audio: String) {
		self.eventId = eventId
		self.audio = audio
	}
}

public struct RealtimeInputAudioBufferCommitEvent: Encodable, Sendable {
	public let type = "input_audio_buffer.commit"
	public let eventId: String?

	public init(eventId: String? = nil) {
		self.eventId = eventId
	}
}

public struct RealtimeInputAudioBufferClearEvent: Encodable, Sendable {
	public let type = "input_audio_buffer.clear"
	public let eventId: String?

	public init(eventId: String? = nil) {
		self.eventId = eventId
	}
}
