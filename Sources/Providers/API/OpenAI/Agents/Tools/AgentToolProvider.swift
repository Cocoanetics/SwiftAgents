//
//  AgentToolProvider.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 19.05.25.
//

import Foundation
import SwiftMCP

public struct AgentToolProvider: MCPToolProviding {
    public let toolName: String
    public let toolDescription: String

    // Type-erased closure to run the specific agent
    private let _runAgentAndGetOutput: (String) async throws -> (Encodable & Sendable)

    public init<A: Agent>(
        agent: A,
        toolName: String? = nil,
        toolDescription: String? = nil,
        config: RunConfig = RunConfig()
    ) where A.OutputType: Encodable & Sendable { // OutputType must be Encodable & Sendable
        self.toolName = toolName ?? agent.name
        self.toolDescription = toolDescription ?? (agent.handoffDescription ?? "Agent tool for \(agent.name)")

        // This closure captures 'agent' with its concrete type 'A'.
        // Runner.run can then be called with a concrete agent type.
        self._runAgentAndGetOutput = { inputText in
            let runResult = try await Runner.run(agent: agent, input: inputText, maxTurns: 30, config: config)
            return runResult.finalOutput
        }
    }

    public nonisolated var mcpToolMetadata: [MCPToolMetadata] {
        [
            MCPToolMetadata(
                name: toolName,
                description: toolDescription,
                parameters: [
                    .init(
                        name: "input", // The tool, as presented to LLM, takes a string "input"
                        type: String.self,
                        isRequired: true
                    )
                ],
				isAsync: true,
				isThrowing: true
            )
        ]
    }

    public func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> Encodable & Sendable {
        guard name == self.toolName else {
            throw MCPToolError.unknownTool(name: name)
        }
        let inputArgument: String = try arguments.extractParameter(named: "input")
        return try await self._runAgentAndGetOutput(inputArgument)
    }
}
