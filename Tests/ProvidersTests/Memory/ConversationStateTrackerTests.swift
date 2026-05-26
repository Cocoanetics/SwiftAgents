//
//  ConversationStateTrackerTests.swift
//  ProvidersTests
//
//  Verifies the cross-provider chain semantics: latest-non-nil id wins,
//  LM Studio stateless sentinels never clobber a real id, conversation_id
//  is tracked independently of the chain.
//

import Foundation
@testable import Providers
import Testing

struct ConversationStateTrackerTests {
    @Test("Default state is empty")
    func defaultEmpty() async {
        let tracker = ConversationStateTracker()
        #expect(await tracker.previousResponseId == nil)
        #expect(await tracker.conversationId == nil)
    }

    @Test("update from response with valid id sets the chain pointer")
    func updateFromValidResponse() async {
        let tracker = ConversationStateTracker()
        await tracker.update(from: Self.makeResponse(id: "resp_1"))
        #expect(await tracker.previousResponseId == "resp_1")
    }

    @Test("update from response with empty id preserves the prior id")
    func updateWithEmptyIdPreserves() async {
        let tracker = ConversationStateTracker()
        await tracker.update(from: Self.makeResponse(id: "resp_first"))
        await tracker.update(from: Self.makeResponse(id: ""))
        #expect(await tracker.previousResponseId == "resp_first")
    }

    @Test("Empty response id does not clobber a real chain id")
    func emptyIdDoesNotClobber() async {
        let tracker = ConversationStateTracker()
        await tracker.update(from: Self.makeResponse(id: "resp_real"))
        await tracker.update(from: Self.makeResponse(id: ""))
        #expect(await tracker.previousResponseId == "resp_real")
    }

    @Test("resetChain clears previousResponseId, leaves conversationId alone")
    func resetChain() async {
        let tracker = ConversationStateTracker(
            conversationId: "conv_123",
            previousResponseId: "resp_abc"
        )
        await tracker.resetChain()
        #expect(await tracker.previousResponseId == nil)
        #expect(await tracker.conversationId == "conv_123")
    }

    @Test("setConversationId is independent of chain")
    func setConversationId() async {
        let tracker = ConversationStateTracker()
        await tracker.setConversationId("conv_xyz")
        #expect(await tracker.conversationId == "conv_xyz")
        #expect(await tracker.previousResponseId == nil)
    }

    @Test("setPreviousResponseId rejects empty strings")
    func setPreviousResponseIdRejectsEmpty() async {
        let tracker = ConversationStateTracker()
        await tracker.setPreviousResponseId("resp_good")
        #expect(await tracker.previousResponseId == "resp_good")

        // An empty string is not a usable chain pointer — prior id stays.
        await tracker.setPreviousResponseId("")
        #expect(await tracker.previousResponseId == "resp_good")
    }

    // MARK: - Helpers

    private static func makeResponse(id: String) -> Response {
        Response(
            id: id,
            createdAt: Date(),
            completedAt: Date(),
            status: .completed,
            background: nil,
            error: nil,
            incompleteDetails: nil,
            instructions: nil,
            maxOutputTokens: nil,
            model: "test-model",
            output: [],
            outputText: nil,
            parallelToolCalls: nil,
            previousResponseId: nil,
            reasoning: nil,
            temperature: nil,
            text: TextConfiguration(format: .text),
            toolChoice: .auto,
            tools: [],
            topP: nil,
            truncation: nil,
            usage: nil,
            user: nil,
            metadata: nil,
            serviceTier: nil
        )
    }
}
