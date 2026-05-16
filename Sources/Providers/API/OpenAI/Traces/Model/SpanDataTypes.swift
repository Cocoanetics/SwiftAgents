import Foundation
import SwiftMCP

// MARK: - Span Data Types

/// Represents an Agent Span in the trace.
/// Includes name, handoffs, tools, and output type.
public struct AgentSpanData: SpanData {
    public let name: String
    public let handoffs: [String]?
    public let tools: [String]?
    public let outputType: String?

    public init(name: String, handoffs: [String]? = nil, tools: [String]? = nil, outputType: String? = nil) {
        self.name = name
        self.handoffs = handoffs
        self.tools = tools
        self.outputType = outputType
    }

    public var type: String {
        "agent"
    }

    public func export() -> [String: JSONValue] {
        return [
            "type": JSONValue(type),
            "name": JSONValue(name),
            "handoffs": JSONValue(handoffs),
            "tools": JSONValue(tools),
            "output_type": JSONValue(outputType)
        ]
    }
}

/// Represents a Function Span in the trace.
/// Includes input, output and MCP data (if applicable).
public struct FunctionSpanData: SpanData {
    public let name: String
    public let input: String?
    public let output: JSONValue?
    public let mcpData: [String: JSONValue]?

    public init(name: String, input: String? = nil, output: JSONValue? = nil, mcpData: [String: JSONValue]? = nil) {
        self.name = name
        self.input = input
        self.output = output
        self.mcpData = mcpData
    }

    public var type: String {
        "function"
    }

    public func export() -> [String: JSONValue] {
        return [
            "type": JSONValue(type),
            "name": JSONValue(name),
            "input": JSONValue(input),
            "output": JSONValue(output?.description),
            "mcp_data": JSONValue(mcpData)
        ]
    }
}

/// Represents a Generation Span in the trace.
/// Includes input, output, model, model configuration, and usage.
public struct GenerationSpanData: SpanData {
    public let input: [[String: JSONValue]]?
    public let output: [[String: JSONValue]]?
    public let model: String?
    public let modelConfig: [String: JSONValue]?
    public let usage: [String: JSONValue]?

    public init(
        input: [[String: JSONValue]]? = nil,
        output: [[String: JSONValue]]? = nil,
        model: String? = nil,
        modelConfig: [String: JSONValue]? = nil,
        usage: [String: JSONValue]? = nil
    ) {
        self.input = input
        self.output = output
        self.model = model
        self.modelConfig = modelConfig
        self.usage = usage
    }

    public var type: String {
        "generation"
    }

    public func export() -> [String: JSONValue] {
        return [
            "type": JSONValue(type),
            "input": JSONValue(input),
            "output": JSONValue(output),
            "model": JSONValue(model),
            "model_config": JSONValue(modelConfig),
            "usage": JSONValue(usage)
        ]
    }
}

/// Represents a Response Span in the trace.
/// Includes response and input.
public struct ResponseSpanData: SpanData {
    public let response: Response?
    public let input: Response.Input?

    public init(response: Response? = nil, input: Response.Input? = nil) {
        self.response = response
        self.input = input
    }

    public var type: String {
        "response"
    }

    public func export() -> [String: JSONValue] {
        return [
            "type": JSONValue(type),
            "response_id": JSONValue(response?.id)
        ]
    }
}

/// Represents a Handoff Span in the trace.
/// Includes source and destination agents.
public struct HandoffSpanData: SpanData {
    public let fromAgent: String?
    public let toAgent: String?

    public init(fromAgent: String? = nil, toAgent: String? = nil) {
        self.fromAgent = fromAgent
        self.toAgent = toAgent
    }

    public var type: String {
        "handoff"
    }

    public func export() -> [String: JSONValue] {
        return [
            "type": JSONValue(type),
            "from_agent": JSONValue(fromAgent),
            "to_agent": JSONValue(toAgent)
        ]
    }
}

/// Represents a Custom Span in the trace.
/// Includes name and data property bag.
public struct CustomSpanData: SpanData {
    public let name: String
    public let data: [String: JSONValue]

    public init(name: String, data: [String: JSONValue] = [:]) {
        self.name = name
        self.data = data
    }

    public var type: String {
        "custom"
    }

    public func export() -> [String: JSONValue] {
        return [
            "type": JSONValue(type),
            "name": JSONValue(name),
            "data": JSONValue(data)
        ]
    }
}

/// Represents a Guardrail Span in the trace.
/// Includes name and triggered status.
public struct GuardrailSpanData: SpanData {
    public let name: String
    public let triggered: Bool

    public init(name: String, triggered: Bool = false) {
        self.name = name
        self.triggered = triggered
    }

    public var type: String {
        "guardrail"
    }

    public func export() -> [String: JSONValue] {
        return [
            "type": JSONValue(type),
            "name": JSONValue(name),
            "triggered": JSONValue(triggered)
        ]
    }
}

/// Represents a Transcription Span in the trace.
/// Includes input, output, model, and model configuration.
public struct TranscriptionSpanData: SpanData {
    public let input: String?
    public let inputFormat: String?
    public let output: String?
    public let model: String?
    public let modelConfig: [String: JSONValue]?

    public init(
        input: String? = nil,
        inputFormat: String? = "pcm",
        output: String? = nil,
        model: String? = nil,
        modelConfig: [String: JSONValue]? = nil
    ) {
        self.input = input
        self.inputFormat = inputFormat
        self.output = output
        self.model = model
        self.modelConfig = modelConfig
    }

    public var type: String {
        "transcription"
    }

    public func export() -> [String: JSONValue] {
        return [
            "type": JSONValue(type),
            "input": JSONValue([
                "data": JSONValue(input ?? ""),
                "format": JSONValue(inputFormat)
            ]),
            "output": JSONValue(output),
            "model": JSONValue(model),
            "model_config": JSONValue(modelConfig)
        ]
    }
}

/// Represents a Speech Span in the trace.
/// Includes input, output, model, model configuration, and first content timestamp.
public struct SpeechSpanData: SpanData {
    public let input: String?
    public let output: String?
    public let outputFormat: String?
    public let model: String?
    public let modelConfig: [String: JSONValue]?
    public let firstContentAt: String?

    public init(
        input: String? = nil,
        output: String? = nil,
        outputFormat: String? = "pcm",
        model: String? = nil,
        modelConfig: [String: JSONValue]? = nil,
        firstContentAt: String? = nil
    ) {
        self.input = input
        self.output = output
        self.outputFormat = outputFormat
        self.model = model
        self.modelConfig = modelConfig
        self.firstContentAt = firstContentAt
    }

    public var type: String {
        "speech"
    }

    public func export() -> [String: JSONValue] {
        return [
            "type": JSONValue(type),
            "input": JSONValue(input),
            "output": JSONValue([
                "data": JSONValue(output ?? ""),
                "format": JSONValue(outputFormat)
            ]),
            "model": JSONValue(model),
            "model_config": JSONValue(modelConfig),
            "first_content_at": JSONValue(firstContentAt)
        ]
    }
}

/// Represents a Speech Group Span in the trace.
public struct SpeechGroupSpanData: SpanData {
    public let input: String?

    public init(input: String? = nil) {
        self.input = input
    }

    public var type: String {
        "speech_group"
    }

    public func export() -> [String: JSONValue] {
        return [
            "type": JSONValue(type),
            "input": JSONValue(input)
        ]
    }
}

/// Represents an MCP List Tools Span in the trace.
/// Includes server and result.
public struct MCPListToolsSpanData: SpanData {
    public let server: String?
    public let result: [String]?

    public init(server: String? = nil, result: [String]? = nil) {
        self.server = server
        self.result = result
    }

    public var type: String {
        "mcp_tools"
    }

    public func export() -> [String: JSONValue] {
        return [
            "type": JSONValue(type),
            "server": JSONValue(server),
            "result": JSONValue(result)
        ]
    }
}
