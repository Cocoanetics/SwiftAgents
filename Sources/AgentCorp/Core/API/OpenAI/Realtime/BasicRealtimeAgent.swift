import Foundation
import SwiftMCP

public final class BasicRealtimeAgent: RealtimeAgent, @unchecked Sendable {
	public typealias OutputType = String

	public let name: String
	public let instructions: String
	public let handoffDescription: String?
	public let toolProviders: [MCPToolProviding]
	public let tools: [Tool]
	public let mcpServers: [MCPServerProxy]
	public let handoffs: [any Handoff]
	public let model: String?
	public let modelSettings: ModelSettings
	public let inputGuardrails: [any InputGuardrail]
	public let outputGuardrails: [any OutputGuardrail]
	public let sessionConfiguration: RealtimeSessionConfiguration

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
		sessionConfiguration: RealtimeSessionConfiguration = RealtimeSessionConfiguration(outputModalities: [.text])
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

		var resolvedSessionConfiguration = sessionConfiguration
		if resolvedSessionConfiguration.instructions == nil {
			resolvedSessionConfiguration.instructions = instructions
		}
		if resolvedSessionConfiguration.maxOutputTokens == nil, let maxCompletionTokens = modelSettings.maxCompletionTokens {
			resolvedSessionConfiguration.maxOutputTokens = .finite(maxCompletionTokens)
		}
		if resolvedSessionConfiguration.toolChoice == nil {
			resolvedSessionConfiguration.toolChoice = modelSettings.toolChoice
		}
		if resolvedSessionConfiguration.outputModalities == nil {
			resolvedSessionConfiguration.outputModalities = [.text]
		}
		self.sessionConfiguration = resolvedSessionConfiguration
	}
}
