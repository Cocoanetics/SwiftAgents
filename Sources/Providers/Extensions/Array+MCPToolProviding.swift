//
//  Array+MCPToolProviding.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 24.04.25.
//

import Foundation
import SwiftMCP

extension Array where Element == MCPToolProviding {
	public func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> any Encodable & Sendable {

		for toolProvider in self {
			guard toolProvider.mcpToolMetadata.contains(where: { $0.name == name })
			else { continue }

			return try await toolProvider.callTool(name, arguments: arguments)
		}

		throw MCPToolError.unknownTool(name: name)
	}

	public func perform(_ toolCall: ToolCall) async -> ToolOutput {
		guard toolCall.type == "function" else {
			return ToolOutput(toolCallId: toolCall.id, output: "Error: Unknown tool call type `\(toolCall.type)`")
		}

		guard let functionCall = toolCall.function else {
			return ToolOutput(toolCallId: toolCall.id, output: "Error: Missing function call details")
		}

		do {
			let result = try await callTool(functionCall.name, arguments: functionCall.argumentsDictionary())

			if let string = result as? String {
				return ToolOutput(toolCallId: toolCall.id, output: string)
			}

			let jsonEncoder = JSONEncoder()
			jsonEncoder.outputFormatting = [.prettyPrinted]
			jsonEncoder.dateEncodingStrategy = .iso8601
			let data = try jsonEncoder.encode(result)
			let string = String(data: data, encoding: .utf8) ?? "Error: Failed to serialize JSON result"

			return ToolOutput(toolCallId: toolCall.id, output: string)

		} catch {
			return ToolOutput(toolCallId: toolCall.id, output: "Error: \(error.localizedDescription)")
		}
	}

	public func perform(_ toolCalls: [ToolCall]) async -> [ToolOutput] {
		await withTaskGroup(of: ToolOutput.self) { group in
			for toolCall in toolCalls {
				group.addTask {
					await perform(toolCall)
				}
			}

			return await group.reduce(into: [ToolOutput]()) { $0.append($1) }
		}
	}
}
