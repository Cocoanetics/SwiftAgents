//
//  ResponsesStreamEvent.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 26.04.25.
//

import Foundation

/** Represents an event emitted when streaming responses.

 - SeeAlso: [Responses Stream Events API](https://platform.openai.com/docs/api-reference/responses-streaming/events)
 */
public struct ResponsesStreamEvent: Sendable {
    /// The type of the event.
    public let type: String

    /// The object associated with the event.
    public let object: Object

    // MARK: - Struct

    /// Represents the object associated with a response streaming event.
    public enum Object: Sendable {
        /// A response object emitted when a response is created.
        case responseCreated(Response)

        /// A response object emitted when a response is in progress.
        case responseInProgress(Response)

        /// A response object emitted when a response is completed.
        case responseCompleted(Response)

        /// A response object emitted when a response has failed.
        case responseFailed(Response)

        /// A response object emitted when a response is incomplete.
        case responseIncomplete(Response)

        /// An output item that was added to the response.
        case outputItemAdded(OutputItemInfo)

        /// An output item that was marked done.
        case outputItemDone(OutputItemInfo)

        /// A content part that was added to an output item.
        case contentPartAdded(ContentPartInfo)

        /// A content part that was marked done.
        case contentPartDone(ContentPartInfo)

        /// An additional text delta that was added.
        case outputTextDelta(OutputTextDeltaInfo)

        /// A text annotation that was added.
        case outputTextAnnotationAdded(OutputTextAnnotationInfo)

        /// Emitted when text content is finalized.
        case outputTextDone(OutputTextDoneInfo)

        /// Emitted when there is a partial refusal text.
        case refusalDelta(RefusalDeltaInfo)

        /// Emitted when refusal text is finalized.
        case refusalDone(RefusalDoneInfo)

        /// Emitted when there is a partial function-call arguments delta.
        case functionCallArgumentsDelta(FunctionCallArgumentsDeltaInfo)

        /// Emitted when function-call arguments are finalized.
        case functionCallArgumentsDone(FunctionCallArgumentsDoneInfo)

        /// Emitted when a file search call is initiated.
        case fileSearchCallInProgress(FileSearchCallInfo)

        /// Emitted when a file search is currently searching.
        case fileSearchCallSearching(FileSearchCallInfo)

        /// Emitted when a file search call is completed (results found).
        case fileSearchCallCompleted(FileSearchCallInfo)

        /// Emitted when a web search call is initiated.
        case webSearchCallInProgress(WebSearchCallInfo)

        /// Emitted when a web search is currently searching.
        case webSearchCallSearching(WebSearchCallInfo)

        /// Emitted when a web search call is completed.
        case webSearchCallCompleted(WebSearchCallInfo)

        /// Emitted when a new reasoning summary part is added.
        case reasoningSummaryPartAdded(ReasoningSummaryPartInfo)

        /// Emitted when a reasoning summary part is completed.
        case reasoningSummaryPartDone(ReasoningSummaryPartInfo)

        /// Emitted when a delta is added to a reasoning summary text.
        case reasoningSummaryText(ReasoningSummaryInfo)

        /// Emitted when there is a reasoning text delta.
        case reasoningTextDelta(ReasoningTextDeltaInfo)

        /// Emitted when reasoning text is finalized.
        case reasoningTextDone(ReasoningTextDoneInfo)

        /// An error object.
        case error(ErrorDetail)
    }
}

public extension ResponsesStreamEvent {
    /// Delta info for reasoning text streaming.
    struct ReasoningTextDeltaInfo: Codable, Sendable {
        public let itemId: String
        public let outputIndex: Int
        public let contentIndex: Int
        public let delta: String
    }

    /// Done info for reasoning text streaming.
    struct ReasoningTextDoneInfo: Codable, Sendable {
        public let itemId: String
        public let outputIndex: Int
        public let contentIndex: Int
        public let text: String
    }
}
