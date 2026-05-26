//
//  SessionResumeIntegrationTests.swift
//  ProvidersTests
//
//  End-to-end exercise of the Session abstraction: a session is passed to
//  two consecutive `Runner.run` calls and the second turn references
//  context provided in the first. Gated on OPENAI_API_KEY so it doesn't
//  block PRs without keys.
//

import Foundation
@testable import Providers
import Testing

struct SessionResumeIntegrationTests {
    @Test(
        "Session preserves context across consecutive Runner.run calls",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func sessionResumesAcrossRuns() async throws {
        let agent = BasicAgent(
            name: "Memorizer",
            model: "gpt-4.1",
            instructions: """
            You remember everything the user tells you. Answer concisely.
            """,
            modelSettings: ModelSettings(temperature: 0)
        )

        let session = InMemorySession()

        _ = try await Runner.run(
            agent: agent,
            input: "Remember: my favourite colour is blue.",
            session: session,
            maxTurns: 3
        )

        let afterFirst = await session.getItems(limit: nil)
        #expect(afterFirst.count >= 2, "expected at least user + assistant items, got \(afterFirst.count)")

        let second = try await Runner.run(
            agent: agent,
            input: "What colour did I say was my favourite?",
            session: session,
            maxTurns: 3
        )

        #expect(second.finalOutput.lowercased().contains("blue"))

        let afterSecond = await session.getItems(limit: nil)
        #expect(afterSecond.count > afterFirst.count)
    }

    @Test(
        "Scalar previousResponseId resume: lastResponseId from one run chains the next",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func scalarResumeViaLastResponseId() async throws {
        let agent = BasicAgent(
            name: "Memorizer",
            model: "gpt-4.1",
            instructions: """
            You remember everything the user tells you. Answer concisely.
            """,
            modelSettings: ModelSettings(temperature: 0)
        )

        let first = try await Runner.run(
            agent: agent,
            input: "Remember: the secret word is platypus.",
            maxTurns: 3
        )
        let resumeId = try #require(first.lastResponseId, "first run should return a chain pointer")

        let second = try await Runner.run(
            agent: agent,
            input: "What was the secret word?",
            previousResponseId: resumeId,
            maxTurns: 3
        )

        #expect(second.finalOutput.lowercased().contains("platypus"))
    }
}
