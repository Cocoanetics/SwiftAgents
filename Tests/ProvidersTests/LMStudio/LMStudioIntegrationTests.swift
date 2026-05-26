//
//  LMStudioIntegrationTests.swift
//  ProvidersTests
//
//  Live tests against a running LM Studio instance. Gated on LMSTUDIO_URL —
//  set it to something like `http://localhost:1234` to enable, otherwise
//  these are skipped on CI / local runs.
//
//  Requires the LM Studio server to have at least one model loaded; the
//  model id is read from `LMSTUDIO_MODEL` (defaults to `qwen3-coder`).
//

import Foundation
@testable import Providers
import Testing

struct LMStudioIntegrationTests {
    private var modelId: String {
        ProcessInfo.processInfo.environment["LMSTUDIO_MODEL"] ?? "qwen3-coder"
    }

    @Test("Native chat endpoint returns a Response", .enabled(if: TestClients.hasLMStudio, "Requires LMSTUDIO_URL"))
    func nativeChatRoundtrip() async throws {
        let client = try TestClients.lmStudio()
        let response = try await client.createResponse(
            input: .text("Reply with just the word OK."),
            model: modelId,
            temperature: 0
        )
        #expect(!response.id.isEmpty)
        #expect(!response.output.isEmpty)
    }

    @Test(
        "Chaining via previous_response_id continues the conversation",
        .enabled(if: TestClients.hasLMStudio, "Requires LMSTUDIO_URL")
    )
    func chainedTurns() async throws {
        let client = try TestClients.lmStudio()

        let first = try await client.createResponse(
            input: .text("My favourite colour is blue. Remember that."),
            model: modelId,
            temperature: 0
        )
        #expect(!first.id.isEmpty)
        // LM Studio returns standard `resp_…` ids on its OpenAI-compat
        // Responses endpoint, identical in shape to OpenAI's. Asserting
        // a real id is set ensures the chain test below has something
        // to chain off.
        #expect(first.id.hasPrefix("resp_"))

        let second = try await client.createResponse(
            input: .text("What colour did I mention?"),
            model: modelId,
            previousResponseId: first.id,
            temperature: 0
        )
        #expect(!second.id.isEmpty)
    }
}
