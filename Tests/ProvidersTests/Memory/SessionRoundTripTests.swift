//
//  SessionRoundTripTests.swift
//  ProvidersTests
//
//  Verifies that the `OutputItem -> Response.Input.Element` lift performed
//  by the Runner produces session items that round-trip cleanly back to
//  the wire shape stateless providers expect (tool_calls on assistant
//  messages, tool result messages, structured output content). The
//  offline tests exercise the conversion chain end-to-end; the live tests
//  (gated on `OPENAI_API_KEY`) run two consecutive `Runner.run` calls
//  against the same `InMemorySession` and assert the second turn picks up
//  context from the first.
//

import Foundation
import Tracing
@testable import Providers
import SwiftMCP
import Testing

// MARK: - Offline: tool-call round-trip through InMemorySession

struct SessionRoundTripOfflineTests {
    @Test("Assistant tool_call lifted into a session round-trips into a foldable ChatMessage")
    func toolCallSessionRoundTrip() async throws {
        // Simulate one turn's output items: assistant text + a function call.
        let outputs: [OutputItem] = [
            .message(.init(
                id: "msg_1",
                role: .assistant,
                status: .completed,
                content: [.outputText(.init(text: "Looking up the weather…", annotations: []))]
            )),
            .functionCall(.init(
                id: "fc_1",
                callId: "call_w",
                name: "get_weather",
                arguments: "{\"city\":\"Berlin\"}",
                status: .completed
            ))
        ]
        let toolOutput: Response.Input.Element = .functionCallOutput(.init(
            callId: "call_w",
            output: "18C and cloudy in Berlin"
        ))

        // The runner does exactly this dance: lift outputs, append, then
        // append tool outputs to the same session.
        let session = InMemorySession()
        await session.addItems([.userMessage("What's the weather in Berlin?")])
        let responseElements = outputs.compactMap { $0.toInputElement() }
        await session.addItems(responseElements)
        await session.addItems([toolOutput])

        let stored = await session.getItems(limit: nil)
        #expect(stored.count == 4)

        // Convert the session back into ChatMessages the way the
        // chat-completions branch does for the next turn.
        let messages = Response.Input.array(stored).toChatMessage()

        // Expect: user, assistant(text + toolCalls), tool(result).
        #expect(messages.count == 3)
        #expect(messages[0].role == .user)
        #expect(messages[1].role == .assistant)
        #expect(messages[1].toolCalls?.first?.id == "call_w")
        #expect(messages[1].textContent == "Looking up the weather…")
        #expect(messages[2].role == .tool)
        #expect(messages[2].toolCallID == "call_w")
        #expect(messages[2].textContent == "18C and cloudy in Berlin")
    }

    @Test("Structured-output assistant message lifted into a session keeps the JSON content")
    func structuredOutputSessionRoundTrip() async throws {
        let json = "{\"colour\":\"green\",\"confidence\":0.9}"
        let outputs: [OutputItem] = [
            .message(.init(
                id: "msg_2",
                role: .assistant,
                status: .completed,
                content: [.outputText(.init(text: json, annotations: []))]
            ))
        ]
        let session = InMemorySession()
        await session.addItems([.userMessage("What colour is grass?")])
        await session.addItems(outputs.compactMap { $0.toInputElement() })

        let stored = await session.getItems(limit: nil)
        #expect(stored.count == 2)

        // Lift the stored assistant element back to a ChatMessage and
        // confirm the JSON survived (so the next turn sees it as prior
        // assistant context). Assistant content must encode as
        // `output_text` on the wire — covered by the same code path.
        guard case let .message(msg) = stored[1] else {
            Issue.record("Expected message element for assistant turn")
            return
        }
        #expect(msg.role == .assistant)
        guard case let .outputText(roundTripped) = msg.content.first else {
            Issue.record("Expected outputText content")
            return
        }
        #expect(roundTripped == json)

        let messages = Response.Input.array(stored).toChatMessage()
        #expect(messages.count == 2)
        #expect(messages[1].role == .assistant)
        #expect(messages[1].textContent == json)
    }
}

// MARK: - Live: cross-Runner.run session reuse with tools + structured output

@MCPServer
private class RoundTripWeatherTools {
    @MCPTool(description: "Returns the current weather for a city")
    func get_weather(city: String) -> String {
        "It is 18°C and partly cloudy in \(city)."
    }
}

@Schema
private struct ColourGuess: Codable, Equatable {
    let colour: String
    let confidence: Double
}

private final class StructuredColourAgent: Agent {
    typealias OutputType = ColourGuess
    let name = "RoundTripColourAgent"
    let model: String? = "gpt-4.1"
    let instructions = "Decide what colour a thing usually is. Answer with structured JSON."
    let modelSettings = ModelSettings(temperature: 0)
}

struct SessionRoundTripLiveTests {
    @Test(
        "Tool-call run + follow-up share state via InMemorySession",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func toolCallSessionResumeLive() async throws {
        let session = InMemorySession()
        let agent = BasicAgent(
            name: "RoundTripWeatherAgent",
            model: "gpt-4.1",
            instructions: """
                Call get_weather when asked about weather, then summarise. \
                Remember previously discussed cities for follow-up questions.
                """,
            toolProvider: [RoundTripWeatherTools()],
            modelSettings: ModelSettings(temperature: 0)
        )

        try await withTrace(name: "Weather memory session") {
            _ = try await Runner.run(
                agent: agent,
                input: "What's the weather in Berlin?",
                session: session,
                maxTurns: 5
            )

            let afterFirst = await session.getItems(limit: nil)
            // user msg + (assistant text? +) tool call + tool output +
            // final assistant — at minimum 4 items.
            #expect(afterFirst.count >= 4, "expected tool-call items in session, got \(afterFirst.count)")
            let sawFunctionCall = afterFirst.contains { element in
                if case .functionCall = element { return true }
                return false
            }
            let sawFunctionCallOutput = afterFirst.contains { element in
                if case .functionCallOutput = element { return true }
                return false
            }
            #expect(sawFunctionCall, "expected the tool call to be persisted in the session")
            #expect(sawFunctionCallOutput, "expected the tool output to be persisted in the session")

            let second = try await Runner.run(
                agent: agent,
                input: "Which city did I just ask about?",
                session: session,
                maxTurns: 3
            )
            // If the session round-trips properly, the model sees the
            // prior user message + tool exchange and answers "Berlin".
            #expect(second.finalOutput.lowercased().contains("berlin"))
        }
    }

    @Test(
        "Structured-output run + follow-up share state via InMemorySession",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func structuredOutputSessionResumeLive() async throws {
        let session = InMemorySession()
        let agent = StructuredColourAgent()

        try await withTrace(name: "Colour memory session") {
            let first = try await Runner.run(
                agent: agent,
                input: "What colour is grass?",
                session: session,
                maxTurns: 3
            )
            #expect(!first.finalOutput.colour.isEmpty)

            let afterFirst = await session.getItems(limit: nil)
            // user + assistant (the structured JSON) at minimum
            #expect(afterFirst.count >= 2)
            // Find the assistant message holding the JSON.
            let assistant = afterFirst.first { element in
                if case let .message(msg) = element, msg.role == .assistant { return true }
                return false
            }
            #expect(assistant != nil, "expected the assistant's structured turn in the session")

            let second = try await Runner.run(
                agent: agent,
                input: "What about the sky?",
                session: session,
                maxTurns: 3
            )
            // The second turn produces another ColourGuess; verifying
            // it decoded at all proves the round-trip didn't poison
            // the chat history with malformed assistant content.
            #expect(!second.finalOutput.colour.isEmpty)
        }
    }
}
