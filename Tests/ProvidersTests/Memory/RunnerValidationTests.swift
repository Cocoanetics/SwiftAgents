//
//  RunnerValidationTests.swift
//  ProvidersTests
//
//  Validates Runner.run's mutual-exclusivity rule between Session and the
//  scalar conversation-pointer kwargs. Mirrors Python's
//  `validate_session_conversation_settings` semantics.
//

import Foundation
@testable import Providers
import Testing

struct RunnerValidationTests {
    private let agent = BasicAgent(
        name: "ValidatorAgent",
        model: "gpt-4.1",
        instructions: "no-op"
    )

    @Test("Session alone is fine")
    func sessionAloneIsValid() async {
        do {
            try Runner.validateSessionConversationSettings(
                session: InMemorySession(),
                conversationId: nil,
                previousResponseId: nil,
                autoPreviousResponseId: false
            )
        } catch {
            Issue.record("Session alone should not throw: \(error)")
        }
    }

    @Test("Session + previousResponseId is rejected")
    func sessionPlusPreviousResponseIdThrows() {
        #expect(throws: SessionConversationConfigurationError.self) {
            try Runner.validateSessionConversationSettings(
                session: InMemorySession(),
                conversationId: nil,
                previousResponseId: "resp_abc",
                autoPreviousResponseId: false
            )
        }
    }

    @Test("Session + conversationId is rejected")
    func sessionPlusConversationIdThrows() {
        #expect(throws: SessionConversationConfigurationError.self) {
            try Runner.validateSessionConversationSettings(
                session: InMemorySession(),
                conversationId: "conv_xyz",
                previousResponseId: nil,
                autoPreviousResponseId: false
            )
        }
    }

    @Test("Session + autoPreviousResponseId is rejected")
    func sessionPlusAutoFlagThrows() {
        #expect(throws: SessionConversationConfigurationError.self) {
            try Runner.validateSessionConversationSettings(
                session: InMemorySession(),
                conversationId: nil,
                previousResponseId: nil,
                autoPreviousResponseId: true
            )
        }
    }

    @Test("No Session: any combination of scalar kwargs is allowed")
    func noSessionIsAlwaysValid() {
        do {
            try Runner.validateSessionConversationSettings(
                session: nil,
                conversationId: "conv_xyz",
                previousResponseId: "resp_abc",
                autoPreviousResponseId: true
            )
        } catch {
            Issue.record("Scalar kwargs without session should not throw: \(error)")
        }
    }

    @Test(
        "Runner.run surfaces the validation error directly",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func runnerRunThrowsOnInvalidCombination() async {
        await #expect(throws: SessionConversationConfigurationError.self) {
            _ = try await Runner.run(
                agent: agent,
                input: "hi",
                session: InMemorySession(),
                previousResponseId: "resp_abc"
            )
        }
    }
}
