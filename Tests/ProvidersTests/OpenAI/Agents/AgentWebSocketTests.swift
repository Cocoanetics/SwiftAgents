//
//  AgentWebSocketTests.swift
//  SwiftAgents
//
//  Agents-SDK integration tests that drive the full run loop over the Responses
//  WebSocket transport — both the non-streaming (`Runner.run`) and streaming
//  (`Runner.runStreamed`) paths — by injecting an `OpenAIResponsesWebSocket`
//  via `RunConfig.api`. Gated on `APIKey.hasOpenAI` so they run locally with a
//  key and skip in CI.
//
//  Where `ResponsesWebSocketIntegrationTests` exercises the transport directly,
//  these prove the seam into the agent loop: that `config.api` routing,
//  `dispatchCreateResponse` (non-streaming), the streamed-turn branch, tool
//  calling, and chaining all work end-to-end over one persistent socket.
//

import Foundation
@testable import Agents
@testable import Providers
import SwiftMCP
import Testing

@Suite(.serialized)
struct AgentWebSocketTests {
    private let model = "gpt-4.1"

    @Test("Non-streaming agent run over WebSocket", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func nonStreamingRun() async throws {
        let webSocket = OpenAIResponsesWebSocket()
        let agent = BasicAgent(
            name: "WS Assistant",
            model: model,
            instructions: "You are terse. Answer in one short sentence."
        )

        let result = try await Runner.run(agent: agent, input: "Say hello.", config: RunConfig(api: webSocket))
        #expect(!result.finalOutput.isEmpty)

        await webSocket.disconnect()
    }

    @Test(
        "Non-streaming tool-calling run drives multiple turns over one socket",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func nonStreamingToolRun() async throws {
        let webSocket = OpenAIResponsesWebSocket()
        let agent = BasicAgent(
            name: "WS Calculator",
            model: model,
            instructions: "Use the multiply tool for any multiplication, then state the result.",
            toolProvider: [WebSocketCalculatorTool()]
        )

        // turn 1 → function_call, turn 2 (chained over the same socket) → answer.
        let result = try await Runner.run(
            agent: agent,
            input: "What is 6 times 7? Use the tool.",
            maxTurns: 5,
            config: RunConfig(api: webSocket)
        )
        #expect(result.finalOutput.contains("42"))

        await webSocket.disconnect()
    }

    @Test(
        "Streaming agent run over WebSocket yields deltas and a final message",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func streamingRun() async throws {
        let webSocket = OpenAIResponsesWebSocket()
        let agent = BasicAgent(
            name: "WS Streamer",
            model: model,
            instructions: "Reply with one short sentence."
        )

        let result = Runner.runStreamed(
            agent: agent,
            input: "Name three primary colors in one sentence.",
            config: RunConfig(api: webSocket)
        )

        var deltaCount = 0
        var finalMessage = ""
        for try await event in result.events {
            switch event {
                case let .rawResponseEvent(streamEvent):
                    if case .outputTextDelta = streamEvent.object {
                        deltaCount += 1
                    }
                case let .runItemEvent(name, item):
                    if name == .messageOutputCreated, case let .message(text) = item {
                        finalMessage = text
                    }
                case .agentUpdated:
                    break
            }
        }

        // Token-by-token deltas streamed over the socket, and the loop surfaced
        // a completed assistant message.
        #expect(deltaCount > 0)
        #expect(!finalMessage.isEmpty)

        await webSocket.disconnect()
    }
}

@MCPServer
final class WebSocketCalculatorTool {
    @MCPTool(description: "Multiply two numbers")
    func multiply(lhs: Double, rhs: Double) -> Double {
        lhs * rhs
    }
}
