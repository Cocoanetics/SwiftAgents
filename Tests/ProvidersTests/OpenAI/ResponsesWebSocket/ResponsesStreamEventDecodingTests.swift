//
//  ResponsesStreamEventDecodingTests.swift
//  SwiftAgents
//
//  Offline coverage for the shared event-frame decoder
//  (`ResponsesStreamEvent.init?(from:decoder:)`). This is the one mapping both
//  the HTTP SSE loop and the WebSocket receive loop route through, so getting
//  it right is what lets the socket reuse the entire Responses event model.
//

import Foundation
@testable import Providers
import Testing

struct ResponsesStreamEventDecodingTests {
    private let decoder = OpenAI(credential: Credential.bearer("test")).decoder

    /// A minimal but decode-valid `response.<terminal>` frame for the given id.
    private func responseFrame(type: String, id: String) -> Data {
        Data(
            """
            {
              "type": "\(type)",
              "response": {
                "id": "\(id)",
                "object": "response",
                "created_at": 1741477868,
                "status": "completed",
                "model": "gpt-5.1",
                "output": [],
                "parallel_tool_calls": true,
                "text": { "format": { "type": "text" } },
                "tool_choice": "auto",
                "tools": [],
                "metadata": {}
              }
            }
            """.utf8
        )
    }

    @Test("response.completed decodes to a chainable Response")
    func decodesCompleted() throws {
        let event = try #require(
            try ResponsesStreamEvent(from: responseFrame(type: "response.completed", id: "resp_1"), decoder: decoder)
        )
        #expect(event.type == "response.completed")
        guard case let .responseCompleted(response) = event.object else {
            Issue.record("Expected .responseCompleted, got \(event.object)")
            return
        }
        // The id is what the agent loop chains the next turn from.
        #expect(response.id == "resp_1")
    }

    @Test("response.incomplete is treated as a terminal Response event")
    func decodesIncomplete() throws {
        let event = try #require(
            try ResponsesStreamEvent(from: responseFrame(type: "response.incomplete", id: "resp_2"), decoder: decoder)
        )
        guard case let .responseIncomplete(response) = event.object else {
            Issue.record("Expected .responseIncomplete, got \(event.object)")
            return
        }
        #expect(response.id == "resp_2")
    }

    @Test("response.output_text.delta decodes its payload")
    func decodesTextDelta() throws {
        let frame = Data(
            """
            {
              "type": "response.output_text.delta",
              "item_id": "item_1",
              "output_index": 0,
              "content_index": 0,
              "delta": "Hello"
            }
            """.utf8
        )
        let event = try #require(try ResponsesStreamEvent(from: frame, decoder: decoder))
        guard case let .outputTextDelta(info) = event.object else {
            Issue.record("Expected .outputTextDelta, got \(event.object)")
            return
        }
        #expect(info.delta == "Hello")
        #expect(info.itemId == "item_1")
    }

    @Test("Unrecognized event types return nil rather than throwing")
    func unrecognizedReturnsNil() throws {
        let frame = Data(#"{"type":"response.some_future_event","payload":{"x":1}}"#.utf8)
        // Forward-compatible events must be skippable so they can't tear down a
        // long-lived connection.
        let event = try ResponsesStreamEvent(from: frame, decoder: decoder)
        #expect(event == nil)
    }

    @Test("A malformed recognized payload throws")
    func malformedRecognizedThrows() {
        // `response.completed` is recognized, but the nested response is missing
        // required fields (id, status, model, …) — that is a real decode error.
        let frame = Data(#"{"type":"response.completed","response":{"object":"response"}}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try ResponsesStreamEvent(from: frame, decoder: decoder)
        }
    }

    @Test("error frame surfaces previous_response_not_found via code")
    func errorFrameCarriesCode() throws {
        let frame = Data(
            """
            {
              "type": "error",
              "code": "previous_response_not_found",
              "message": "Previous response not found",
              "param": "previous_response_id"
            }
            """.utf8
        )
        let event = try #require(try ResponsesStreamEvent(from: frame, decoder: decoder))
        guard case let .error(detail) = event.object else {
            Issue.record("Expected .error, got \(event.object)")
            return
        }
        #expect(detail.code == "previous_response_not_found")
        #expect(detail.param == "previous_response_id")
    }
}
