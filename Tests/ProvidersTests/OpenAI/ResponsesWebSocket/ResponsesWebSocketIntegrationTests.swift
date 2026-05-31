//
//  ResponsesWebSocketIntegrationTests.swift
//  SwiftAgents
//
//  Integration tests for the Responses WebSocket transport, gated on
//  `APIKey.hasOpenAI` so they run whenever `OPENAI_API_KEY` is available
//  (locally via `.env`) and skip in CI — the same pattern as the other
//  network-backed suites (`ChatTests`, `ResponseSwiftTestingTest`, …).
//
//  These exercise the transport directly (`dispatchCreateResponse` /
//  `streamResponse` / `warmup`) against the live API, covering what the offline
//  mock-socket suite (`ResponsesWebSocketModelTests`) cannot: that the handshake
//  to `wss://api.openai.com/v1/responses` succeeds with Bearer-only auth, that
//  real server frames decode through the shared event model, and that chaining
//  and streaming work end-to-end. Agent-loop coverage lives in
//  `AgentWebSocketTests`.
//

import Foundation
@testable import Providers
import Testing

@Suite(.serialized)
struct ResponsesWebSocketIntegrationTests {
    /// A current general-purpose model available on the Responses API.
    private let model = "gpt-4.1"

    @Test("A single turn assembles a real Response", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func singleTurn() async throws {
        let webSocket = OpenAIResponsesWebSocket()
        let response = try await webSocket.dispatchCreateResponse(
            input: .text("Reply with exactly the word: pong"),
            model: model,
            instructions: "You are a terse test fixture. Follow the user exactly.",
            previousResponseId: nil,
            conversationId: nil,
            textFormat: .text,
            tools: nil,
            modelSettings: ModelSettings(store: false)
        )

        // The handshake succeeded, a real frame decoded, and we got a chainable id.
        #expect(!response.id.isEmpty)
        #expect(response.status == .completed)
        let cached = await webSocket.lastResponseId()
        #expect(cached == response.id)

        await webSocket.disconnect()
    }

    @Test("A streamed turn yields real deltas", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func streamedTurn() async throws {
        let webSocket = OpenAIResponsesWebSocket()

        let stream = webSocket.streamResponse(
            input: .text("Count slowly: one two three four five."),
            model: model,
            instructions: nil,
            previousResponseId: nil,
            tools: nil,
            modelSettings: ModelSettings(store: false)
        )

        var deltaCount = 0
        var assembledText = ""
        var completedId: String?
        for try await event in stream {
            switch event.object {
                case let .outputTextDelta(info):
                    deltaCount += 1
                    assembledText += info.delta
                case let .responseCompleted(response):
                    completedId = response.id
                default:
                    break
            }
        }

        // Real incremental deltas arrived (the whole point of streaming), the
        // stream closed on a terminal Response, and the id is chainable.
        #expect(deltaCount > 0)
        #expect(!assembledText.isEmpty)
        #expect(completedId.map { !$0.isEmpty } ?? false)

        await webSocket.disconnect()
    }

    @Test("A second turn chains over the same socket", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func chainedTurns() async throws {
        let webSocket = OpenAIResponsesWebSocket()

        let first = try await webSocket.dispatchCreateResponse(
            input: .text("My favorite color is teal. Acknowledge with one word."),
            model: model,
            instructions: nil,
            previousResponseId: nil,
            conversationId: nil,
            textFormat: .text,
            tools: nil,
            modelSettings: ModelSettings(store: false)
        )
        #expect(!first.id.isEmpty)

        // Chain from the first turn over the SAME connection — the fast path.
        let second = try await webSocket.dispatchCreateResponse(
            input: .text("What did I say my favorite color was? One word."),
            model: model,
            instructions: nil,
            previousResponseId: first.id,
            conversationId: nil,
            textFormat: .text,
            tools: nil,
            modelSettings: ModelSettings(store: false)
        )

        #expect(!second.id.isEmpty)
        #expect(second.id != first.id)
        // The model recalled prior-turn context → chaining genuinely worked.
        // Read the text the way the run loop does — from the output items, not
        // the SDK-aggregated `outputText` convenience (which the loop ignores).
        #expect(Self.assistantText(second).lowercased().contains("teal"))

        await webSocket.disconnect()
    }

    @Test("warmup returns a chainable id", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func warmupReturnsChainableId() async throws {
        let webSocket = OpenAIResponsesWebSocket()

        let warmed = try await webSocket.warmup(
            model: model,
            instructions: "You are a terse test fixture.",
            input: .array([.userMessage("Remember the number 42.")]),
            modelSettings: ModelSettings(store: false)
        )
        #expect(!warmed.id.isEmpty)
        let cached = await webSocket.lastResponseId()
        #expect(cached == warmed.id)

        await webSocket.disconnect()
    }

    /// Concatenate assistant message text from a `Response`'s output items —
    /// the same `output → .message → .content → .outputText` path the agent run
    /// loop reads, rather than the aggregated `Response.outputText` convenience.
    private static func assistantText(_ response: Response) -> String {
        response.output.reduce(into: "") { text, item in
            guard case let .message(message) = item else { return }
            for content in message.content {
                if case let .outputText(output) = content {
                    text += output.text
                }
            }
        }
    }
}
