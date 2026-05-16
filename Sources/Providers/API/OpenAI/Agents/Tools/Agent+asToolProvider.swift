//
//  Agent+asTool.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 19.05.25.
//


// MARK: - Agent as ToolProvider

public extension Agent where OutputType: Encodable & Sendable {
	/**
	 Convenience method to wrap the current agent in an `AgentToolProvider`.

	 This allows the agent to be used as a tool by other agents via the `MCPToolProviding` mechanism.
	 The tool will take a single string "input" and the agent will be executed with this input.
	 The agent's `OutputType` must be `Encodable & Sendable`.

	 - Parameters:
	   - toolName: The name for the tool. Defaults to the agent's name.
	   - toolDescription: The description for the tool. Defaults to the agent's `handoffDescription` or a generic description.
	 - Returns: An `AgentToolProvider` instance configured with this agent.
	 */
	func asToolProvider(
		toolName: String? = nil,
		toolDescription: String? = nil,
		config: RunConfig = RunConfig()
	) -> AgentToolProvider {
		AgentToolProvider(
			agent: self,
			toolName: toolName,
			toolDescription: toolDescription,
			config: config
		)
	}
}