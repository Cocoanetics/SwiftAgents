//
//  OpenAI+Assistants.swift
//
//
//  Created by Oliver Drobnik on 01.05.24.
//

import Foundation

extension OpenAI {
	// MARK: - Assistants

	func createAssistant(
		model: String,
		name: String? = nil,
		description: String? = nil,
		instructions: String? = nil,
		tools: [ToolDescription]? = nil,
		toolResources: ToolResources? = nil,
		metadata: [String: String] = [:],
		topP: Double = 1,
		temperature: Double = 1,
		responseFormat: ResponseFormat = .auto
	) async throws -> Assistant {

		let assistant = AssistantOptionals(name: name, description: description, model: model, instructions: instructions, tools: tools, toolResources: toolResources, metadata: metadata, topP: topP, temperature: temperature, responseFormat: responseFormat)
		let request = try self.createUrlRequest(httpMethod: "POST", path: "/v1/assistants", body: assistant)

		let (data, response) = try await session.data(for: request)

		return try process(data: data, response: response)
	}

	func listAssistants(limit: Int = 20, order: SortOrder = .descending, after: String? = nil, before: String? = nil) async throws -> ListPagedResponse<Assistant> {
		var queryItems: [URLQueryItem] = [
			URLQueryItem(name: "limit", value: String(limit)),
			URLQueryItem(name: "order", value: order.rawValue)
		]

		if let after = after {
			queryItems.append(URLQueryItem(name: "after", value: after))
		}

		if let before = before {
			queryItems.append(URLQueryItem(name: "before", value: before))
		}

		let request = try self.createUrlRequest(path: "/v1/assistants", queryItems: queryItems)

		let (data, response) = try await session.data(for: request)

		let list: ListPagedResponse<Assistant> = try process(data: data, response: response)

		return list
	}

	func retrieveAssistant(id: String) async throws -> Assistant {
		let request = try self.createUrlRequest(path: "/v1/assistants/" + id)

		let (data, response) = try await session.data(for: request)

		return try process(data: data, response: response)
	}

	func modifyAssistent(
		id: String,
		model: String? = nil,
		name: String? = nil,
		description: String? = nil,
		instructions: String? = nil,
		tools: [ToolDescription]? = nil,
		toolResources: ToolResources? = nil,
		metadata: [String: String] = [:],
		topP: Double? = nil,
		temperature: Double? = nil,
		responseFormat: ResponseFormat? = nil
	) async throws -> Assistant {
		let tmpAssistant = AssistantOptionals(name: name, description: description, model: model, instructions: instructions, tools: tools, toolResources: toolResources, metadata: metadata, topP: topP, temperature: temperature, responseFormat: responseFormat)

		let request = try self.createUrlRequest(httpMethod: "POST", path: "/v1/assistants/" + id, body: tmpAssistant)

		let (data, response) = try await session.data(for: request)

		return try process(data: data, response: response)
	}

	@discardableResult func deleteAssistant(id: String) async throws -> Bool {
		let request = try self.createUrlRequest(httpMethod: "DELETE", path: "/v1/assistants/" + id)

		let (data, response) = try await session.data(for: request)

		let deletionStatus: DeletionStatus = try process(data: data, response: response)

		return deletionStatus.deleted
	}
}
