//
//  BasicAgent.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 19.05.25.
//

import Foundation
import SwiftMCP

/// An agent that can perform tasks using natural language instructions.
public final class BasicAgent: Agent, @unchecked Sendable {

	public typealias OutputType = String

	/// The name of the agent.
	public let name: String

	/// The instructions that define the agent's behavior.
	public let instructions: String

	/// A description of the agent. This is used when the agent is used as a handoff, so that an LLM knows what it does and when to invoke it.
	public let handoffDescription: String?

	/// The tools available to the agent.
	public let toolProviders: [MCPToolProviding]

	/// Tool descriptions available
	public let tools: [Tool]

	/// MCP Servers to include as tools
	public let mcpServers: [MCPServerProxy]

	/// Handoffs that are available to the agent
	public let handoffs: [any Handoff]

	/// An override to specify the model to be used
	public let model: String?

	/// Model settings to apply
	public let modelSettings: ModelSettings

	/// Guardrails evaluated on the very first input before the agent loop
	public let inputGuardrails: [any InputGuardrail]

	/// Guardrails evaluated on the final output before returning from Runner.run.
	public let outputGuardrails: [any OutputGuardrail]

	/// Creates a new agent with the specified configuration.
	/// - Parameters:
	///   - name: The name of the agent
	///   - instructions: The instructions that define the agent's behavior
	///   - toolProvider: The tools available to the agent
	///   - outputType: The format in which the agent should output its responses
	public init(
		name: String,
		model: String? = nil,
		instructions: String,
		handoffDescription: String? = nil,
		toolProvider: [MCPToolProviding] = [],
		tools: [Tool] = [],
		mcpServers: [MCPServerProxy] = [],
		modelSettings: ModelSettings = ModelSettings(),
		handoffs: [any Handoff] = [],
		inputGuardrails: [any InputGuardrail] = [],
		outputGuardrails: [any OutputGuardrail] = [],
		outputType: TextFormat = .text,
		output: Any.Type = String.self
	) {
		self.name = name
		self.instructions = instructions
		self.handoffDescription = handoffDescription
		self.toolProviders = toolProvider
		self.tools = tools
		self.mcpServers = mcpServers
		self.modelSettings = modelSettings
		self.handoffs = handoffs
		self.model = model
		self.inputGuardrails = inputGuardrails
		self.outputGuardrails = outputGuardrails
	}
}

public extension Array where Element == MCPToolProviding {
	var tools: [Tool] {
		return self.flatMap { $0.toolDescriptions }.compactMap { desc -> Tool? in
			guard let function = desc.function else { return nil }
			return Tool.function(FunctionTool(
				name: function.name,
				description: function.description,
				parameters: function.parameters,
				strict: true
			))
		}
	}
}
