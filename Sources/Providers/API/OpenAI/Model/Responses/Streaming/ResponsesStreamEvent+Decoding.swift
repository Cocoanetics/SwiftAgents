//
//  ResponsesStreamEvent+Decoding.swift
//  SwiftAgents
//
//  The single source of truth for mapping a Responses stream event `type`
//  to its decoded `Object` payload. Shared by both transports:
//
//  - the HTTP SSE byte stream (`OpenAI.processResponseEventStream`), which
//    reads the discriminator from the `event:` line, and
//  - the WebSocket transport (`OpenAIResponsesWebSocketModel`), where each
//    frame is one complete JSON object carrying a top-level `type`.
//
//  Both feed the same configured `openAI.decoder` (snake_case keys,
//  secondsSince1970 dates, base64 data), so every nested `Response`,
//  `*Info`, and `ErrorDetail` decodes identically regardless of channel.
//

import Foundation

/// Minimal probe that reads only the `type` discriminator from an event frame.
private struct ResponsesEventTypeProbe: Decodable {
    let type: String
}

/// Envelope for events whose payload is a whole `Response` nested under the
/// `response` key (`response.created`, `.completed`, `.failed`, …).
private struct ResponsesResponseEnvelope: Decodable {
    let response: Response
}

/// Decode the `Response` nested under the `response` key.
///
/// A free function rather than a method on `ResponsesStreamEvent.Object` so it
/// can be called inside the enum's self-assigning initializer without tripping
/// definite-initialization ("'self' used before 'self.init'").
private func decodeResponse(from json: Data, decoder: JSONDecoder) throws -> Response {
    try decoder.decode(ResponsesResponseEnvelope.self, from: json).response
}

/// Decode an `error` event. OpenAI sends a bare `ErrorDetail`; LM Studio wraps
/// it in `{ "error": … }`. Try the bare shape first, then the wrapper —
/// matching the historical SSE behavior.
private func decodeErrorDetail(from json: Data, decoder: JSONDecoder) throws -> ErrorDetail {
    if let bare = try? decoder.decode(ErrorDetail.self, from: json) {
        return bare
    }
    return try decoder.decode(ErrorResponse.self, from: json).error
}

public extension ResponsesStreamEvent {
    /// Decode one complete Responses event JSON object — a single WebSocket
    /// frame.
    ///
    /// Reads the top-level `type` discriminator and dispatches to the matching
    /// payload via ``ResponsesStreamEvent/Object/init(type:json:decoder:)``.
    ///
    /// - Returns: `nil` when `type` is not one this SDK models. Callers skip
    ///   such events (`else { continue }`), so a forward-compatible event the
    ///   server adds later never tears down a long-lived connection.
    /// - Throws: only when a *recognized* event's payload is malformed — that
    ///   is a real bug worth surfacing for the turn in flight.
    init?(from data: Data, decoder: JSONDecoder) throws {
        let type = try decoder.decode(ResponsesEventTypeProbe.self, from: data).type
        guard let object = try Object(type: type, json: data, decoder: decoder) else {
            return nil
        }
        self.init(type: type, object: object)
    }
}

public extension ResponsesStreamEvent.Object {
    /// Build the event payload for a known `type`, decoding `json` with the
    /// supplied (OpenAI-configured) decoder.
    ///
    /// This is the one place the event → payload table lives; the SSE path and
    /// the WebSocket path both route through it so they can never drift.
    ///
    /// - Returns: `nil` for an unrecognized `type` (the caller decides whether
    ///   to ignore or warn); a non-nil payload otherwise.
    /// - Throws: if a recognized event's payload fails to decode.
    init?(type: String, json: Data, decoder: JSONDecoder) throws {
        switch type {
            case "response.created":
                self = try .responseCreated(decodeResponse(from: json, decoder: decoder))
            case "response.in_progress":
                self = try .responseInProgress(decodeResponse(from: json, decoder: decoder))
            case "response.completed":
                self = try .responseCompleted(decodeResponse(from: json, decoder: decoder))
            case "response.failed":
                self = try .responseFailed(decodeResponse(from: json, decoder: decoder))
            case "response.incomplete":
                self = try .responseIncomplete(decodeResponse(from: json, decoder: decoder))
            case "response.output_item.added":
                self = try .outputItemAdded(decoder.decode(ResponsesStreamEvent.OutputItemInfo.self, from: json))
            case "response.output_item.done":
                self = try .outputItemDone(decoder.decode(ResponsesStreamEvent.OutputItemInfo.self, from: json))
            case "response.content_part.added":
                self = try .contentPartAdded(decoder.decode(ResponsesStreamEvent.ContentPartInfo.self, from: json))
            case "response.content_part.done":
                self = try .contentPartDone(decoder.decode(ResponsesStreamEvent.ContentPartInfo.self, from: json))
            case "response.output_text.delta":
                self = try .outputTextDelta(decoder.decode(ResponsesStreamEvent.OutputTextDeltaInfo.self, from: json))
            case "response.output_text.annotation.added":
                self = try .outputTextAnnotationAdded(
                    decoder.decode(ResponsesStreamEvent.OutputTextAnnotationInfo.self, from: json)
                )
            case "response.output_text.done":
                self = try .outputTextDone(decoder.decode(ResponsesStreamEvent.OutputTextDoneInfo.self, from: json))
            case "response.refusal.delta":
                self = try .refusalDelta(decoder.decode(ResponsesStreamEvent.RefusalDeltaInfo.self, from: json))
            case "response.refusal.done":
                self = try .refusalDone(decoder.decode(ResponsesStreamEvent.RefusalDoneInfo.self, from: json))
            case "response.function_call_arguments.delta":
                self = try .functionCallArgumentsDelta(
                    decoder.decode(ResponsesStreamEvent.FunctionCallArgumentsDeltaInfo.self, from: json)
                )
            case "response.function_call_arguments.done":
                self = try .functionCallArgumentsDone(
                    decoder.decode(ResponsesStreamEvent.FunctionCallArgumentsDoneInfo.self, from: json)
                )
            case "response.file_search_call.in_progress":
                self = try .fileSearchCallInProgress(
                    decoder.decode(ResponsesStreamEvent.FileSearchCallInfo.self, from: json)
                )
            case "response.file_search_call.searching":
                self = try .fileSearchCallSearching(
                    decoder.decode(ResponsesStreamEvent.FileSearchCallInfo.self, from: json)
                )
            case "response.file_search_call.completed":
                self = try .fileSearchCallCompleted(
                    decoder.decode(ResponsesStreamEvent.FileSearchCallInfo.self, from: json)
                )
            case "response.web_search_call.in_progress":
                self = try .webSearchCallInProgress(
                    decoder.decode(ResponsesStreamEvent.WebSearchCallInfo.self, from: json)
                )
            case "response.web_search_call.searching":
                self = try .webSearchCallSearching(
                    decoder.decode(ResponsesStreamEvent.WebSearchCallInfo.self, from: json)
                )
            case "response.web_search_call.completed":
                self = try .webSearchCallCompleted(
                    decoder.decode(ResponsesStreamEvent.WebSearchCallInfo.self, from: json)
                )
            case "response.reasoning_summary_part.added":
                self = try .reasoningSummaryPartAdded(
                    decoder.decode(ResponsesStreamEvent.ReasoningSummaryPartInfo.self, from: json)
                )
            case "response.reasoning_summary_part.done":
                self = try .reasoningSummaryPartDone(
                    decoder.decode(ResponsesStreamEvent.ReasoningSummaryPartInfo.self, from: json)
                )
            case "response.reasoning_summary.text":
                self = try .reasoningSummaryText(
                    decoder.decode(ResponsesStreamEvent.ReasoningSummaryInfo.self, from: json)
                )
            case "response.reasoning_text.delta":
                self = try .reasoningTextDelta(
                    decoder.decode(ResponsesStreamEvent.ReasoningTextDeltaInfo.self, from: json)
                )
            case "response.reasoning_text.done":
                self = try .reasoningTextDone(
                    decoder.decode(ResponsesStreamEvent.ReasoningTextDoneInfo.self, from: json)
                )
            case "error":
                self = try .error(decodeErrorDetail(from: json, decoder: decoder))
            default:
                return nil
        }
    }
}
