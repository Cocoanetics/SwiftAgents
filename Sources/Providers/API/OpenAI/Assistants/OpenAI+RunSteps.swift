//
//  OpenAI+RunSteps.swift
//
//
//  Created by Oliver Drobnik on 03.05.24.
//

import Foundation

extension OpenAI
{
	/**
	 Retrieves a list of run steps belonging to a specific run on the OpenAI platform.
	 
	 - Parameters:
	 - threadId: The unique identifier of the thread to which the run steps belong.
	 - runId: The unique identifier of the run whose steps are to be listed.
	 - limit: Optional. The maximum number of run steps to return, default is 20.
	 - order: Optional. The order of the run steps returned, either "asc" for ascending or "desc" for descending.
	 - after: Optional. A cursor for pagination; specifies an object ID to list run steps after it.
	 - before: Optional. A cursor for pagination; specifies an object ID to list run steps before it.
	 
	 - Returns: Returns a `ListPagedResponse<RunStep>` object containing the list of run steps for the given run.
	 
	 - SeeAlso: [List Run Steps API](https://platform.openai.com/docs/api-reference/run-steps/listRunSteps)
	 */
	func listRunSteps(threadId: String,
					  runId: String,
					  limit: Int = 20,
					  order: SortOrder = .descending,
					  after: String? = nil,
					  before: String? = nil) async throws -> ListPagedResponse<RunStep>
	{
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
		
		let request = try self.createUrlRequest(path: "/v1/threads/\(threadId)/runs/\(runId)/steps", queryItems: queryItems)
		
		let (data, response) = try await URLSession.shared.data(for: request)
		
		return try process(data: data, response: response)
	}
}
