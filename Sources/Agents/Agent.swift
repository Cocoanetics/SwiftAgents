import Foundation
import Providers
import SwiftMCP
import Tracing

/// A conversational agent: instructions plus tools, MCP servers, handoffs,
/// and guardrails, executed by `Runner` (`Runner.run` / `Runner.runStreamed`).
///
/// Protocol extension defaults make every requirement optional except
/// `name`, `instructions`, and the `OutputType` associated type, which
/// conformers must declare (e.g. `typealias OutputType = String`, as
/// `BasicAgent` does).
public protocol Agent: AnyObject, Sendable {
    /// The type of the agent's final output. When it conforms to
    /// `SchemaRepresentable` (or is an array of schema-representable
    /// elements), `outputType` switches the run to structured JSON-schema
    /// output; any other type decodes from the model's plain-text answer.
    associatedtype OutputType: Decodable & Sendable

    /// The name of the agent.
    var name: String { get }

    /// The instructions that define the agent's behavior.
    var instructions: String { get }

    /// A description of the agent. This is used when the agent is used as a handoff, so that an LLM knows what it does
    /// and when to invoke it.
    var handoffDescription: String? { get }

    /// Providers that supply MCP tools to the agent.
    var toolProviders: [MCPToolProviding] { get }

    /// Explicit tool definitions available to the agent, merged with
    /// provider- and handoff-derived tools.
    var tools: [Tool] { get }

    /// MCP Servers to include as tools
    var mcpServers: [MCPServerProxy] { get }

    /// Handoffs that are available to the agent
    var handoffs: [any Handoff] { get }

    /// An override to specify the model to be used
    var model: String? { get }

    /// Model settings to apply
    var modelSettings: ModelSettings { get }

    /// Guardrails evaluated on the very first input before the agent loop.
    var inputGuardrails: [any InputGuardrail] { get }

    /// Guardrails evaluated on the final output before returning from Runner.run.
    var outputGuardrails: [any OutputGuardrail] { get }
}

public extension Agent {
    var handoffs: [any Handoff] {
        []
    }

    var toolProviders: [MCPToolProviding] {
        []
    }

    var tools: [Tool] {
        []
    }

    var mcpServers: [MCPServerProxy] {
        []
    }

    var handoffDescription: String? {
        nil
    }

    var model: String? {
        nil
    }

    var modelSettings: ModelSettings {
        ModelSettings()
    }

    var inputGuardrails: [any InputGuardrail] {
        []
    }

    var outputGuardrails: [any OutputGuardrail] {
        []
    }

    /// The output type to request from Responses API
    var outputType: TextFormat {
        // Check if OutputType is an array whose element describes its schema
        if let arrayType = OutputType.self as? ArrayWithSchemaRepresentableElements.Type {
            // Build the element schema using the provided description
            let elementSchema = arrayType.schema(description: "\(String(describing: arrayType))")

            // Wrap the array into an object schema with "results" as the key
            let objectSchema = JSONSchema.object(
                .init(
                    properties: ["results": elementSchema.addingAdditionalPropertiesRestrictionToObjects],
                    required: ["results"],
                    description: "Wrapper for Array of Results",
                    additionalProperties: false
                )
            )

            return .jsonSchema(JSONSchemaFormat(name: "Results", schema: objectSchema))
        }

        if let type = OutputType.self as? SchemaRepresentable.Type {
            return .jsonSchema(type.jsonSchema)
        }

        return .text
    }

    /// The response format to request from ChatCompletionRequest
    var responseFormat: ChatCompletionRequest.ResponseFormat? {
        switch outputType {
            case .text:
                // workaround for LM Studio bug which complains about this value, so we go with default nil
                return nil
            case .json:
                return .json
            case let .jsonSchema(schemaFormat):
                return .jsonSchema(schemaFormat)
        }
    }

    /// That's the output type name shown in agent spans
    var outputTypeForAgentSpan: String {
        if let type = OutputType.self as? SchemaRepresentable.Type {
            return type.jsonSchema.name
        } else {
            return "str"
        }
    }

    /// Creates a list of tools from the agent's tool providers.
    /// - Returns: An array of tools that the agent can use.
    func createTools() async -> [Tool] {
        // Collect tools from toolProviders and from self if it conforms to MCPToolProviding
        var allProviders = toolProviders
        if let selfProvider = self as? MCPToolProviding {
            allProviders.insert(selfProvider, at: 0)
        }

        let providedTools: [Tool] = if tools.contains(.applyPatch) {
            await allProviders.tools.filter {
                if case let .function(function) = $0 { return !["edit", "write"].contains(function.name) }
                return true
            }
        } else {
            await allProviders.tools
        }

        return tools + providedTools + handoffTools
    }

    func executeToolCalls(_ functionCalls: [OutputItem.FunctionCall]) async throws -> [Response.Input.Element] {
        guard !functionCalls.isEmpty else {
            return []
        }

        var newInputs = [Response.Input.Element]()

        try await withThrowingTaskGroup(of: (String, any Codable & Sendable).self) { group in
            // Build provider list including self if it conforms to MCPToolProviding
            var allProviders = self.toolProviders
            if let selfProvider = self as? MCPToolProviding {
                allProviders.insert(selfProvider, at: 0)
            }

            // Start all function calls in parallel
            for call in functionCalls {
                var matchedProvider: (any MCPToolProviding)?
                for provider in allProviders
                    where await provider.mcpToolMetadata.contains(where: { $0.name == call.name }) {
                    matchedProvider = provider
                    break
                }
                if let toolProvider = matchedProvider {
                    group.addTask {
                        try await withSpan { functionSpan in
                            let result: Encodable

                            do {
                                result = try await toolProvider.callTool(
                                    call.name,
                                    arguments: call.argumentsDictionary()
                                )
                            } catch {
                                if ProcessInfo.processInfo.environment["DEBUG_RESPONSES"] != nil {
                                    NSLog("[DEBUG] Tool '%@' error: %@", call.name, String(describing: error))
                                }
                                result = "Error: \(error.localizedDescription)"
                            }

                            // Create span data for this function call
                            functionSpan.spanData = FunctionSpanData(
                                name: call.name,
                                input: call.arguments,
                                output: JSONValue(result)
                            )

                            // swiftlint:disable:next force_cast - callTool returns Encodable; protocol return requires Codable. Concrete return paths conform in practice.
                            return (call.callId, result as! (any Codable & Sendable))
                        }
                    }
                } else {
                    for mcpServer in mcpServers {
                        let toolDescriptions = try await mcpServer.listTools()
                        let endpointURL = await mcpServer.endpointURL?.absoluteString ?? ""
                        let serverName = await mcpServer.serverName ?? endpointURL

                        if toolDescriptions.contains(where: { $0.name == call.name }) {
                            group.addTask {
                                try await withSpan { functionSpan in
                                    let result: Encodable

                                    do {
                                        result = try await mcpServer.callTool(
                                            call.name,
                                            arguments: call.argumentsDictionary()
                                        )
                                    } catch {
                                        result = error.localizedDescription
                                    }

                                    // Create span data for this function call
                                    functionSpan.spanData = FunctionSpanData(
                                        name: call.name,
                                        input: call.arguments,
                                        output: JSONValue(result),
                                        mcpData: ["server": .string(serverName)]
                                    )

                                    // swiftlint:disable:next force_cast - callTool returns Encodable; protocol return requires Codable. Concrete return paths conform in practice.
                                    return (call.callId, result as! (any Codable & Sendable))
                                }
                            }

                            break
                        }
                    }
                }
            }

            // Process results as they complete
            while let (callId, result) = try await group.next() {
                // Convert result to the model-visible string via the shared
                // serializer (strings pass through to avoid extra quotes).
                let output = try ToolOutputSerialization.string(from: result)

                // Add to inputs for next round
                let inputElement = Response.Input.Element.functionCallOutput(.init(callId: callId, output: output))
                newInputs.append(inputElement)
            }
        }

        return newInputs
    }

    // MARK: - Helpers

    var defaultHandoffDescription: String {
        var string = "Handoff to the \(name) agent to handle the request."

        if let handoffDescription {
            string += " \(handoffDescription)"
        }

        return string
    }

    private var handoffTools: [Tool] {
        handoffs.map { handoff in
            // `SchemaMetadata.schema` performs the shared properties/required
            // reduction (and carries the type-level description along).
            let parameters: JSONSchema = if let schemaType = handoff.inputType.self as? SchemaRepresentable.Type {
                schemaType.schemaMetadata.schema
            } else {
                .object(.init(properties: [:], required: []))
            }

            return Tool.function(
                FunctionTool(
                    name: handoff.toolName,
                    description: handoff.toolDescription,
                    parameters: parameters,
                    strict: false
                )
            )
        }
    }
}
