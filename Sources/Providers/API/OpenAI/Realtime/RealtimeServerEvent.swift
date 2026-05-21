import Foundation
import SwiftMCP

public struct RealtimeResponse: Codable, Sendable {
    public let id: String
    public let status: ResponseStatus?
    public let output: [RealtimeConversationItem]?
    public let conversationId: String?

    public init(
        id: String,
        status: ResponseStatus? = nil,
        output: [RealtimeConversationItem]? = nil,
        conversationId: String? = nil
    ) {
        self.id = id
        self.status = status
        self.output = output
        self.conversationId = conversationId
    }
}

public struct RealtimeServerEvent: Sendable {
    public let type: String
    public let eventId: String?
    public let object: Object

    public enum Object: Sendable {
        case sessionCreated(SessionEvent)
        case sessionUpdated(SessionEvent)
        case conversationCreated(ConversationCreatedEvent)
        case conversationItemCreated(ConversationItemEvent)
        case conversationItemAdded(ConversationItemEvent)
        case conversationItemDone(ConversationItemEvent)
        case conversationItemDeleted(ConversationItemDeletedEvent)
        case conversationItemTruncated(ConversationItemTruncatedEvent)
        // Names mirror OpenAI's Realtime event types; >40 chars by design.
        // swiftlint:disable:next identifier_name
        case conversationItemInputAudioTranscriptionDelta(InputAudioTranscriptionDeltaEvent)
        // swiftlint:disable:next identifier_name
        case conversationItemInputAudioTranscriptionCompleted(InputAudioTranscriptionCompletedEvent)
        case inputAudioBufferSpeechStarted(InputAudioBufferSpeechStartedEvent)
        case inputAudioBufferSpeechStopped(InputAudioBufferSpeechStoppedEvent)
        case responseCreated(ResponseEvent)
        case responseDone(ResponseEvent)
        case responseOutputItemAdded(ResponseOutputItemEvent)
        case responseOutputItemDone(ResponseOutputItemEvent)
        case responseOutputTextDelta(OutputTextDeltaEvent)
        case responseOutputTextDone(OutputTextDoneEvent)
        case responseOutputAudioDelta(OutputAudioDeltaEvent)
        case responseOutputAudioDone(OutputAudioDoneEvent)
        case responseOutputAudioTranscriptDelta(OutputAudioTranscriptDeltaEvent)
        case responseOutputAudioTranscriptDone(OutputAudioTranscriptDoneEvent)
        case responseFunctionCallArgumentsDelta(FunctionCallArgumentsDeltaEvent)
        case responseFunctionCallArgumentsDone(FunctionCallArgumentsDoneEvent)
        case error(ErrorEvent)
        case unknown([String: JSONValue])
    }

    public init(type: String, eventId: String? = nil, object: Object) {
        self.type = type
        self.eventId = eventId
        self.object = object
    }

    static func decode(from data: Data, decoder: JSONDecoder) throws -> RealtimeServerEvent {
        let rawObject = try JSONSerialization.jsonObject(with: data)
        let rawDictionary = rawObject as? [String: Any] ?? [:]
        let eventType = rawDictionary["type"] as? String ?? "unknown"

        func decodePayload<T: Decodable>(_ payloadType: T.Type) throws -> T {
            try decoder.decode(payloadType, from: data)
        }

        switch eventType {
            case "session.created":
                let payload = try decodePayload(SessionEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .sessionCreated(payload))
            case "session.updated":
                let payload = try decodePayload(SessionEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .sessionUpdated(payload))
            case "conversation.created":
                let payload = try decodePayload(ConversationCreatedEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .conversationCreated(payload))
            case "conversation.item.created":
                let payload = try decodePayload(ConversationItemEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .conversationItemCreated(payload))
            case "conversation.item.added":
                let payload = try decodePayload(ConversationItemEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .conversationItemAdded(payload))
            case "conversation.item.done":
                let payload = try decodePayload(ConversationItemEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .conversationItemDone(payload))
            case "conversation.item.deleted":
                let payload = try decodePayload(ConversationItemDeletedEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .conversationItemDeleted(payload))
            case "conversation.item.truncated":
                let payload = try decodePayload(ConversationItemTruncatedEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .conversationItemTruncated(payload))
            case "conversation.item.input_audio_transcription.delta":
                let payload = try decodePayload(InputAudioTranscriptionDeltaEvent.self)
                return .init(
                    type: eventType,
                    eventId: payload.eventId,
                    object: .conversationItemInputAudioTranscriptionDelta(payload)
                )
            case "conversation.item.input_audio_transcription.completed":
                let payload = try decodePayload(InputAudioTranscriptionCompletedEvent.self)
                return .init(
                    type: eventType,
                    eventId: payload.eventId,
                    object: .conversationItemInputAudioTranscriptionCompleted(payload)
                )
            case "input_audio_buffer.speech_started":
                let payload = try decodePayload(InputAudioBufferSpeechStartedEvent.self)
                return .init(
                    type: eventType,
                    eventId: payload.eventId,
                    object: .inputAudioBufferSpeechStarted(payload)
                )
            case "input_audio_buffer.speech_stopped":
                let payload = try decodePayload(InputAudioBufferSpeechStoppedEvent.self)
                return .init(
                    type: eventType,
                    eventId: payload.eventId,
                    object: .inputAudioBufferSpeechStopped(payload)
                )
            case "response.created":
                let payload = try decodePayload(ResponseEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .responseCreated(payload))
            case "response.done":
                let payload = try decodePayload(ResponseEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .responseDone(payload))
            case "response.output_item.added":
                let payload = try decodePayload(ResponseOutputItemEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .responseOutputItemAdded(payload))
            case "response.output_item.done":
                let payload = try decodePayload(ResponseOutputItemEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .responseOutputItemDone(payload))
            case "response.output_text.delta":
                let payload = try decodePayload(OutputTextDeltaEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .responseOutputTextDelta(payload))
            case "response.output_text.done":
                let payload = try decodePayload(OutputTextDoneEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .responseOutputTextDone(payload))
            case "response.output_audio.delta":
                let payload = try decodePayload(OutputAudioDeltaEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .responseOutputAudioDelta(payload))
            case "response.output_audio.done":
                let payload = try decodePayload(OutputAudioDoneEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .responseOutputAudioDone(payload))
            case "response.output_audio_transcript.delta":
                let payload = try decodePayload(OutputAudioTranscriptDeltaEvent.self)
                return .init(
                    type: eventType,
                    eventId: payload.eventId,
                    object: .responseOutputAudioTranscriptDelta(payload)
                )
            case "response.output_audio_transcript.done":
                let payload = try decodePayload(OutputAudioTranscriptDoneEvent.self)
                return .init(
                    type: eventType,
                    eventId: payload.eventId,
                    object: .responseOutputAudioTranscriptDone(payload)
                )
            case "response.function_call_arguments.delta":
                let payload = try decodePayload(FunctionCallArgumentsDeltaEvent.self)
                return .init(
                    type: eventType,
                    eventId: payload.eventId,
                    object: .responseFunctionCallArgumentsDelta(payload)
                )
            case "response.function_call_arguments.done":
                let payload = try decodePayload(FunctionCallArgumentsDoneEvent.self)
                return .init(
                    type: eventType,
                    eventId: payload.eventId,
                    object: .responseFunctionCallArgumentsDone(payload)
                )
            case "error":
                let payload = try decodePayload(ErrorEvent.self)
                return .init(type: eventType, eventId: payload.eventId, object: .error(payload))
            default:
                let raw = rawDictionary.mapValues(JSONValue.init(jsonObject:))
                return .init(type: eventType, eventId: rawDictionary["event_id"] as? String, object: .unknown(raw))
        }
    }
}

public extension RealtimeServerEvent {
    struct SessionEvent: Codable, Sendable {
        public let eventId: String
        public let session: RealtimeSessionConfiguration
    }

    struct ConversationCreatedEvent: Codable, Sendable {
        public struct Conversation: Codable, Sendable {
            public let id: String?
            public let object: String?
        }

        public let eventId: String
        public let conversation: Conversation
    }

    struct ConversationItemEvent: Codable, Sendable {
        public let eventId: String
        public let item: RealtimeConversationItem
        public let previousItemId: String?
    }

    struct ConversationItemDeletedEvent: Codable, Sendable {
        public let eventId: String
        public let itemId: String
    }

    struct ConversationItemTruncatedEvent: Codable, Sendable {
        public let eventId: String
        public let itemId: String
        public let contentIndex: Int
        public let audioEndMs: Int
    }

    struct InputAudioTranscriptionDeltaEvent: Codable, Sendable {
        public let eventId: String
        public let itemId: String
        public let contentIndex: Int
        public let delta: String
    }

    struct InputAudioTranscriptionCompletedEvent: Codable, Sendable {
        public let eventId: String
        public let itemId: String
        public let contentIndex: Int
        public let transcript: String
    }

    /// Server VAD detected the start of user speech in the input audio buffer.
    /// `audioStartMs` is the offset (in ms) from the buffer start; `itemId` is
    /// the user message item the server is creating to capture this turn.
    struct InputAudioBufferSpeechStartedEvent: Codable, Sendable {
        public let eventId: String
        public let audioStartMs: Int
        public let itemId: String
    }

    /// Server VAD detected the end of user speech. `audioEndMs` is the offset
    /// (in ms) where speech stopped; `itemId` matches the speech_started event.
    struct InputAudioBufferSpeechStoppedEvent: Codable, Sendable {
        public let eventId: String
        public let audioEndMs: Int
        public let itemId: String
    }

    struct ResponseEvent: Codable, Sendable {
        public let eventId: String
        public let response: RealtimeResponse
    }

    struct ResponseOutputItemEvent: Codable, Sendable {
        public let eventId: String
        public let responseId: String
        public let outputIndex: Int
        public let item: RealtimeConversationItem
    }

    struct OutputTextDeltaEvent: Codable, Sendable {
        public let eventId: String
        public let responseId: String
        public let itemId: String
        public let outputIndex: Int
        public let contentIndex: Int
        public let delta: String
    }

    struct OutputTextDoneEvent: Codable, Sendable {
        public let eventId: String
        public let responseId: String
        public let itemId: String
        public let outputIndex: Int
        public let contentIndex: Int
        public let text: String
    }

    struct OutputAudioDeltaEvent: Codable, Sendable {
        public let eventId: String
        public let responseId: String
        public let itemId: String
        public let outputIndex: Int
        public let contentIndex: Int
        public let delta: Data?
    }

    struct OutputAudioDoneEvent: Codable, Sendable {
        public let eventId: String
        public let responseId: String
        public let itemId: String
        public let outputIndex: Int
        public let contentIndex: Int
        public let audio: Data?
    }

    struct OutputAudioTranscriptDeltaEvent: Codable, Sendable {
        public let eventId: String
        public let responseId: String
        public let itemId: String
        public let outputIndex: Int
        public let contentIndex: Int
        public let delta: String
    }

    struct OutputAudioTranscriptDoneEvent: Codable, Sendable {
        public let eventId: String
        public let responseId: String
        public let itemId: String
        public let outputIndex: Int
        public let contentIndex: Int
        public let transcript: String
    }

    struct FunctionCallArgumentsDeltaEvent: Codable, Sendable {
        public let eventId: String
        public let responseId: String
        public let itemId: String
        public let outputIndex: Int
        public let callId: String
        public let delta: String
    }

    struct FunctionCallArgumentsDoneEvent: Codable, Sendable {
        public let eventId: String
        public let responseId: String
        public let itemId: String
        public let outputIndex: Int
        public let callId: String
        public let name: String
        public let arguments: String
    }

    struct ErrorEvent: Codable, Sendable {
        public let eventId: String?
        public let error: ErrorDetail
    }
}
