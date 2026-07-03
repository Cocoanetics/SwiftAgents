import Foundation
@testable import Providers
import Testing

struct ConversationAPITests {
    @Test("Conversation can be created and retrieved", LiveGate.openAIState)
    func conversationLifecycle() async throws {
        let openAI = try TestClients.openAI()
        let conversation = try await openAI.createConversation(
            metadata: ["scope": "swift-testing"]
        )

        #expect(conversation.object == "conversation")
        #expect(conversation.metadata?["scope"] == "swift-testing")

        let fetched = try await openAI.retrieveConversation(id: conversation.id)
        #expect(fetched.id == conversation.id)
        #expect(fetched.metadata?["scope"] == "swift-testing")

        _ = try? await openAI.deleteConversation(id: conversation.id)
    }

    @Test("Conversation metadata can be updated", LiveGate.openAIState)
    func conversationUpdate() async throws {
        let openAI = try TestClients.openAI()
        let conversation = try await openAI.createConversation(
            metadata: ["version": "1"]
        )

        let updated = try await openAI.updateConversation(
            id: conversation.id,
            metadata: ["version": "2", "status": "active"]
        )

        #expect(updated.id == conversation.id)
        #expect(updated.metadata?["version"] == "2")
        #expect(updated.metadata?["status"] == "active")

        _ = try? await openAI.deleteConversation(id: conversation.id)
    }

    @Test("Conversation can be deleted", LiveGate.openAIState)
    func conversationDeletion() async throws {
        let openAI = try TestClients.openAI()
        let conversation = try await openAI.createConversation()

        let deleted = try await openAI.deleteConversation(id: conversation.id)
        #expect(deleted == true)
    }

    @Test("Conversation items can be created and listed", LiveGate.openAIState)
    func conversationItemsLifecycle() async throws {
        let openAI = try TestClients.openAI()
        let conversation = try await openAI.createConversation()

        let items: [Response.Input.Element] = [
            .message(Response.Input.Message(role: "user", text: "Hello from Swift Testing.")),
            .message(Response.Input.Message(role: "user", text: "How are you?"))
        ]

        let created = try await openAI.createConversationItems(
            conversationId: conversation.id,
            items: items
        )

        #expect(created.object == "list")
        #expect(created.data.count == 2)

        let listed = try await openAI.listConversationItems(
            conversationId: conversation.id,
            order: .ascending
        )

        #expect(listed.data.count >= 2)

        let firstItem = listed.data.first
        #expect(firstItem?.type == "message")
        #expect(firstItem?.role == "user")

        _ = try? await openAI.deleteConversation(id: conversation.id)
    }

    @Test("Conversation item can be retrieved", LiveGate.openAIState)
    func conversationItemRetrieval() async throws {
        let openAI = try TestClients.openAI()
        let conversation = try await openAI.createConversation(items: [
            .message(Response.Input.Message(role: "user", text: "Test message"))
        ])

        let listed = try await openAI.listConversationItems(conversationId: conversation.id)
        let itemId = try #require(listed.data.first?.id, "Expected at least one item")

        let item = try await openAI.retrieveConversationItem(
            conversationId: conversation.id,
            itemId: itemId
        )

        #expect(item.id == itemId)
        #expect(item.type == "message")

        _ = try? await openAI.deleteConversation(id: conversation.id)
    }

    @Test("Response attached to conversation persists items", LiveGate.openAIState)
    func conversationWithResponse() async throws {
        let openAI = try TestClients.openAI()
        let conversation = try await openAI.createConversation()

        let response = try await openAI.createResponse(
            input: .text("What is 2 + 2? Answer with just the number."),
            model: "gpt-4.1-mini",
            conversation: conversation.id,
            store: true
        )

        #expect(response.status == .completed)

        let listed = try await openAI.listConversationItems(
            conversationId: conversation.id,
            order: .ascending
        )

        // Should contain both the user message and the assistant response
        #expect(listed.data.count >= 2)

        let roles = listed.data.compactMap(\.role)
        #expect(roles.contains("user"))
        #expect(roles.contains("assistant"))

        _ = try? await openAI.deleteConversation(id: conversation.id)
    }

    @Test("Conversation item can be deleted", LiveGate.openAIState)
    func conversationItemDeletion() async throws {
        let openAI = try TestClients.openAI()
        let conversation = try await openAI.createConversation(items: [
            .message(Response.Input.Message(role: "user", text: "To be deleted"))
        ])

        let listed = try await openAI.listConversationItems(conversationId: conversation.id)
        let itemId = try #require(listed.data.first?.id, "Expected at least one item")

        let result = try await openAI.deleteConversationItem(
            conversationId: conversation.id,
            itemId: itemId
        )
        #expect(result.id == conversation.id)

        let afterDeletion = try await openAI.listConversationItems(conversationId: conversation.id)
        let remainingIds = afterDeletion.data.map(\.id)
        #expect(!remainingIds.contains(itemId))

        _ = try? await openAI.deleteConversation(id: conversation.id)
    }
}
