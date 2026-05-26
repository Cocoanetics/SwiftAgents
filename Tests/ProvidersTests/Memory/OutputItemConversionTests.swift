//
//  OutputItemConversionTests.swift
//  ProvidersTests
//
//  Verifies the OutputItem -> Response.Input.Element bridge that lets the
//  Runner persist assistant outputs to a Session and replay them as input
//  on subsequent turns.
//

import Foundation
@testable import Providers
import Testing

struct OutputItemConversionTests {
    @Test("Message output lifts to message input with the same text")
    func messageRoundtrip() {
        let output = OutputItem.message(.init(
            id: "msg_1",
            role: .assistant,
            status: .completed,
            content: [.outputText(.init(text: "Hello there", annotations: []))]
        ))

        guard case let .message(input) = output.toInputElement() else {
            Issue.record("Expected .message input element")
            return
        }
        #expect(input.role == .assistant)
        guard case let .inputText(text) = input.content.first else {
            Issue.record("Expected inputText content")
            return
        }
        #expect(text == "Hello there")
    }

    @Test("Function call lifts to function call input verbatim")
    func functionCallRoundtrip() {
        let call = OutputItem.FunctionCall(
            id: "fc_1",
            callId: "call_1",
            name: "get_weather",
            arguments: "{\"city\":\"Vienna\"}",
            status: .completed
        )
        let output = OutputItem.functionCall(call)

        guard case let .functionCall(round) = output.toInputElement() else {
            Issue.record("Expected .functionCall input element")
            return
        }
        #expect(round.callId == "call_1")
        #expect(round.name == "get_weather")
        #expect(round.arguments == "{\"city\":\"Vienna\"}")
    }

    @Test("Reasoning output is dropped (server-side only)")
    func reasoningDropped() {
        let output = OutputItem.reasoning(.init(
            id: "reasoning_1",
            status: .completed,
            summary: []
        ))
        #expect(output.toInputElement() == nil)
    }

    @Test("userMessage convenience builds a user-role message element")
    func userMessageHelper() {
        let element = Response.Input.Element.userMessage("Hi")
        guard case let .message(msg) = element else {
            Issue.record("Expected .message")
            return
        }
        #expect(msg.role == .user)
        guard case let .inputText(text) = msg.content.first else {
            Issue.record("Expected inputText")
            return
        }
        #expect(text == "Hi")
    }

    // MARK: - toChatMessage tool-call folding

    @Test("Session with assistant text + functionCall folds into one assistant ChatMessage")
    func functionCallFoldsIntoPriorAssistant() {
        let session: [Response.Input.Element] = [
            .userMessage("Get the weather"),
            .message(.init(role: .assistant, text: "Calling the tool")),
            .functionCall(.init(
                id: "fc_1",
                callId: "call_abc",
                name: "get_weather",
                arguments: "{\"city\":\"Vienna\"}",
                status: .completed
            )),
            .functionCallOutput(.init(callId: "call_abc", output: "18°C and sunny"))
        ]
        let messages = Response.Input.array(session).toChatMessage()

        #expect(messages.count == 3)
        #expect(messages[0].role == .user)
        #expect(messages[1].role == .assistant)
        #expect(messages[1].toolCalls?.count == 1)
        #expect(messages[1].toolCalls?.first?.id == "call_abc")
        #expect(messages[1].textContent == "Calling the tool")
        #expect(messages[2].role == .tool)
        #expect(messages[2].toolCallID == "call_abc")
    }

    @Test("A bare functionCall (no prior assistant message) creates a fresh assistant message")
    func functionCallWithoutPriorAssistant() {
        let session: [Response.Input.Element] = [
            .userMessage("Hi"),
            .functionCall(.init(
                id: "fc_2",
                callId: "call_xyz",
                name: "ping",
                arguments: "{}",
                status: .completed
            ))
        ]
        let messages = Response.Input.array(session).toChatMessage()

        #expect(messages.count == 2)
        #expect(messages[1].role == .assistant)
        #expect(messages[1].content == nil)
        #expect(messages[1].toolCalls?.first?.id == "call_xyz")
    }
}
