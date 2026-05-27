//
//  OpenAIConversationsSessionTests.swift
//  ProvidersTests
//
//  Integration tests for the OpenAI-Conversations-backed Session. Gated
//  on OPENAI_API_KEY since each test creates and tears down a real
//  conversation on OpenAI's servers.
//

import Foundation
@testable import Agents
import Tracing
@testable import Providers
import Testing

struct OpenAIConversationsSessionTests {
    @Test(
        "OpenAIConversationsSession lazy-creates a conversation on first use",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func lazyCreate() async throws {
        let client = try TestClients.openAI()
        let session = OpenAIConversationsSession(openAI: client)
        let id = await session.sessionId
        #expect(id.hasPrefix("conv_"))
        try await session.clearSession()
    }

    @Test(
        "addItems / getItems round-trip via the Conversations API",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func addAndGetItems() async throws {
        let client = try TestClients.openAI()
        let session = OpenAIConversationsSession(openAI: client)
        try await session.addItems([
            .userMessage("the secret colour is teal")
        ])

        let items = try await session.getItems(limit: nil)
        #expect(!items.isEmpty)
        let hasTeal = items.contains { element in
            if case let .message(msg) = element,
               case let .inputText(text) = msg.content.first {
                return text.contains("teal")
            }
            return false
        }
        #expect(hasTeal)

        try await session.clearSession()
    }

    @Test(
        "Runner can use OpenAIConversationsSession as a transparent Session",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func runnerWithOpenAIConversationsSession() async throws {
        let client = try TestClients.openAI()
        let session = OpenAIConversationsSession(openAI: client)

        let agent = BasicAgent(
            name: "Memorizer",
            model: "gpt-4.1",
            instructions: "Answer concisely.",
            modelSettings: ModelSettings(temperature: 0)
        )

        try await withTrace(name: "Pixel memory session") {
            _ = try await Runner.run(
                agent: agent,
                input: "Remember: my dog is called Pixel.",
                session: session,
                maxTurns: 3
            )

            let second = try await Runner.run(
                agent: agent,
                input: "What's my dog's name?",
                session: session,
                maxTurns: 3
            )
            #expect(second.finalOutput.lowercased().contains("pixel"))
        }

        try await session.clearSession()
    }
}
