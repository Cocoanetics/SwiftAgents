//
//  OpenAI+ConversationItems.swift
//
//
//  Created by Oliver Drobnik on 14.04.26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension OpenAI {
    /// Creates items in a conversation on the OpenAI platform.
    ///
    /// - Parameters:
    ///   - conversationId: The unique identifier of the conversation to add items to.
    ///   - items: An array of input items to add to the conversation (up to 20 items at a time).
    ///   - include: Optional. Additional output data to include in the response.
    ///
    /// - Returns: Returns a `ConversationItemList` containing the created items.
    ///
    /// - SeeAlso: [Create Conversation Items
    /// API](https://platform.openai.com/docs/api-reference/conversations/create-items)
    func createConversationItems(
        conversationId: String,
        items: [Response.Input.Element],
        include: [Include]? = nil
    ) async throws -> ConversationItemList {
        let body = ConversationItemsCreation(items: items, include: include)
        let request = try createUrlRequest(
            httpMethod: "POST",
            path: "/v1/conversations/\(conversationId)/items",
            body: body
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        return try process(data: data, response: response)
    }

    /// Lists items in a conversation on the OpenAI platform, providing pagination control.
    ///
    /// - Parameters:
    ///   - conversationId: The unique identifier of the conversation whose items are to be listed.
    ///   - limit: Optional. The maximum number of items to return (1-100), default is 20.
    ///   - order: Optional. The sort order of items returned.
    ///   - after: Optional. A cursor for pagination; specifies an item ID to list items after it.
    ///   - include: Optional. Additional output data to include in the response.
    ///
    /// - Returns: Returns a paginated list of conversation items.
    ///
    /// - SeeAlso: [List Conversation Items
    /// API](https://platform.openai.com/docs/api-reference/conversations/list-items)
    func listConversationItems(
        conversationId: String,
        limit: Int = 20,
        order: SortOrder = .descending,
        after: String? = nil,
        include: [Include]? = nil
    ) async throws -> ConversationItemList {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "order", value: order.rawValue)
        ]

        if let after {
            queryItems.append(URLQueryItem(name: "after", value: after))
        }

        if let include {
            for item in include {
                queryItems.append(URLQueryItem(name: "include[]", value: item.rawValue))
            }
        }

        let request = try createUrlRequest(
            path: "/v1/conversations/\(conversationId)/items",
            queryItems: queryItems
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        return try process(data: data, response: response)
    }

    /// Retrieves a specific item from a conversation on the OpenAI platform.
    ///
    /// - Parameters:
    ///   - conversationId: The unique identifier of the conversation.
    ///   - itemId: The unique identifier of the item to retrieve.
    ///   - include: Optional. Additional output data to include in the response.
    ///
    /// - Returns: Returns a `ConversationItem` containing the details of the retrieved item.
    ///
    /// - SeeAlso: [Retrieve Conversation Item
    /// API](https://platform.openai.com/docs/api-reference/conversations/get-item)
    func retrieveConversationItem(
        conversationId: String,
        itemId: String,
        include: [Include]? = nil
    ) async throws -> ConversationItem {
        var queryItems: [URLQueryItem] = []

        if let include {
            for item in include {
                queryItems.append(URLQueryItem(name: "include[]", value: item.rawValue))
            }
        }

        let request = try createUrlRequest(
            path: "/v1/conversations/\(conversationId)/items/\(itemId)",
            queryItems: queryItems.isEmpty ? nil : queryItems
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        return try process(data: data, response: response)
    }

    /// Deletes an item from a conversation on the OpenAI platform.
    ///
    /// - Parameters:
    ///   - conversationId: The unique identifier of the conversation.
    ///   - itemId: The unique identifier of the item to delete.
    ///
    /// - Returns: Returns the parent `Conversation` object.
    ///
    /// - SeeAlso: [Delete Conversation Item
    /// API](https://platform.openai.com/docs/api-reference/conversations/delete-item)
    @discardableResult
    func deleteConversationItem(
        conversationId: String,
        itemId: String
    ) async throws -> Conversation {
        let request = try createUrlRequest(
            httpMethod: "DELETE",
            path: "/v1/conversations/\(conversationId)/items/\(itemId)"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        return try process(data: data, response: response)
    }
}

/// Represents the body for creating items in a conversation.
struct ConversationItemsCreation: Codable {
    /// The items to add to the conversation (up to 20 at a time).
    var items: [Response.Input.Element]

    /// Additional output data to include in the response.
    var include: [Include]?
}
