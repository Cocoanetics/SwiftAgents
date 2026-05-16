import Foundation
import SwiftMCP

extension Runner {
    /// Run an agent with streaming, returning a result object immediately.
    ///
    /// The agent loop runs in a background `Task`, pushing `AgentStreamEvent`s
    /// through the returned `RunResultStreaming.events` stream. The caller
    /// consumes events with `for try await event in result.events { ... }`.
    ///
    /// This mirrors the Python Agents SDK's `Runner.run_streamed()` pattern.
    ///
    /// - Note: Streaming is only supported for OpenAI-backed models using the
    ///   Responses API. For non-OpenAI APIs, falls back to non-streaming
    ///   `Runner.run()` and emits the final output as a single event.
    public static func runStreamed(
        agent: some Agent,
        input: String,
        maxTurns: Int = 10,
        previousResponseId: String? = nil,
        config: RunConfig = RunConfig()
    ) -> RunResultStreaming {
        let (stream, continuation) = AsyncThrowingStream<AgentStreamEvent, Error>.makeStream()

        let resultRef = RunResultStreaming(events: stream, continuation: continuation, task: Task {})

        let task = Task<Void, Error> {
            do {
                try await _runStreamedLoop(
                    agent: agent,
                    input: input,
                    maxTurns: maxTurns,
                    previousResponseId: previousResponseId,
                    config: config,
                    continuation: continuation,
                    resultRef: resultRef
                )
            } catch {
                continuation.finish(throwing: error)
                throw error
            }
        }

        resultRef.task = task
        return resultRef
    }

    // MARK: - Internal Streaming Loop

    // swiftlint:disable:next function_parameter_count
    private static func _runStreamedLoop<A: Agent>(
        agent: A,
        input: String,
        maxTurns: Int,
        previousResponseId: String?,
        config: RunConfig,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        resultRef: RunResultStreaming
    ) async throws {
        if TraceContext.currentTrace == nil {
            return try await withTrace(name: config.workFlowName) {
                try await _runStreamedLoop(
                    agent: agent,
                    input: input,
                    maxTurns: maxTurns,
                    previousResponseId: previousResponseId,
                    config: config,
                    continuation: continuation,
                    resultRef: resultRef
                )
            }
        }

        var currentAgent: A = agent

        repeat {
            let model = config.model ?? currentAgent.model ?? "gpt-4.1"
            let api = try await Providers.shared.api(for: model)

            // Non-OpenAI fallback: use non-streaming Runner.run() and emit final output
            guard let openAI = api as? OpenAI else {
                let runResult: RunResult<A.OutputType> = try await Runner.run(
                    agent: currentAgent,
                    input: input,
                    maxTurns: maxTurns,
                    config: config
                )

                if let output = runResult.finalOutput as? String {
                    continuation.yield(.runItemEvent(
                        name: .messageOutputCreated,
                        item: .message(output)
                    ))
                }

                continuation.finish()
                return
            }

            let result: AgentResult<A.OutputType> = try await withSpan { agentSpan in
                var tools: [Tool] = currentAgent.createTools()

                // List MCP server tools
                for proxy in currentAgent.mcpServers {
                    tools += try await withSpan { mcpListSpan in
                        let serverName = await proxy.serverName
                        let mcpTools = try await proxy.listTools()

                        let myTools = mcpTools.map { mcpTool in
                            let parameters: Parameters = if case let .object(object, _) = mcpTool.inputSchema {
                                Parameters(properties: object.properties)
                            } else {
                                .none
                            }
                            return Tool.function(FunctionTool(
                                name: mcpTool.name,
                                description: mcpTool.description,
                                parameters: parameters,
                                strict: true
                            ))
                        }

                        mcpListSpan.spanData = MCPListToolsSpanData(server: serverName, result: mcpTools.map(\.name))
                        return myTools
                    }
                }

                agentSpan.spanData = AgentSpanData(
                    name: currentAgent.name,
                    handoffs: currentAgent.handoffs.compactMap { $0.targetAgent?.name },
                    tools: tools.map(\.nameForAgentSpan),
                    outputType: currentAgent.outputTypeForAgentSpan
                )

                return try await _executeStreamedTurns(
                    agent: currentAgent,
                    agentSpan: agentSpan,
                    tools: tools,
                    maxTurns: maxTurns,
                    model: model,
                    openAI: openAI,
                    input: .text(input),
                    previousResponseId: previousResponseId,
                    continuation: continuation,
                    resultRef: resultRef
                )
            }

            switch result {
                case .finalOutput:
                    continuation.finish()
                    return
                case let .handOff(nextAgent):
                    if let nextAgentTyped = nextAgent as? A {
                        currentAgent = nextAgentTyped
                        continuation.yield(.agentUpdated(name: currentAgent.name))
                    } else {
                        throw RunnerError.exceededMaxTurns
                    }
            }
        } while true
    }

    // MARK: - Streamed Turn Execution

    // swiftlint:disable:next function_parameter_count
    private static func _executeStreamedTurns<A: Agent>(
        agent: A,
        agentSpan _: TraceSpan,
        tools: [Tool],
        maxTurns: Int,
        model: String,
        openAI: OpenAI,
        input: Response.Input,
        previousResponseId: String?,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        resultRef: RunResultStreaming
    ) async throws -> AgentResult<A.OutputType> {
        var currentInput = input
        var previousResponseId = previousResponseId
        var turns = 0

        while turns < maxTurns {
            turns += 1

            try Task.checkCancellation()

            // Stream model response with tracing
            var functionCalls = [OutputItem.FunctionCall]()
            var applyPatchCalls = [ApplyPatchCallOutput]()
            var completedResponse: Response?
            var roundResult = ""
            var roundReasoning: String?

            try await withSpan { responseSpan in
                responseSpan.spanData = ResponseSpanData(input: currentInput)

                // When continuing a conversation, skip instructions — the API has them via previousResponseId
                let stream = try await openAI.createResponseStream(
                    input: currentInput,
                    model: model,
                    instructions: previousResponseId == nil ? agent.instructions : nil,
                    maxOutputTokens: agent.modelSettings.maxCompletionTokens,
                    metadata: agent.modelSettings.metadata,
                    parallelToolCalls: agent.modelSettings.parallelToolCalls,
                    previousResponseId: previousResponseId,
                    reasoning: agent.modelSettings.reasoning,
                    store: agent.modelSettings.store,
                    temperature: agent.modelSettings.temperature,
                    toolChoice: agent.modelSettings.toolChoice,
                    tools: tools,
                    topP: agent.modelSettings.topP,
                    truncation: agent.modelSettings.truncation
                )

                for try await event in stream {
                    // Forward raw event to caller
                    continuation.yield(.rawResponseEvent(event))

                    switch event.object {
                        case let .outputItemDone(info):
                            switch info.item {
                                case let .functionCall(functionCall):
                                    functionCalls.append(functionCall)
                                    continuation.yield(.runItemEvent(
                                        name: .toolCalled,
                                        item: .toolCall(name: functionCall.name, arguments: functionCall.arguments, callId: functionCall.callId)
                                    ))

                                case let .message(messageOutput):
                                    for content in messageOutput.content {
                                        if case let .outputText(outputText) = content {
                                            roundResult = outputText.text
                                            continuation.yield(.runItemEvent(
                                                name: .messageOutputCreated,
                                                item: .message(outputText.text)
                                            ))
                                        }
                                    }

                                case let .reasoning(reasoningOutput):
                                    roundReasoning = reasoningOutput.summary.map(\.text).joined(separator: "\n\n")

                                case let .applyPatchCall(patchCall):
                                    // Notify caller that a patch call is in progress (diff may be incomplete from
                                    // streaming)
                                    // The operation type (create_file / update_file /
                                    // delete_file) used to be appended in parentheses,
                                    // but the path argument already tells the caller
                                    // what's being touched and the verb only added
                                    // visual noise in chat-style UIs that render the
                                    // tool name on its own line.
                                    continuation.yield(.runItemEvent(
                                        name: .toolCalled,
                                        item: .toolCall(
                                            name: "apply_patch",
                                            arguments: patchCall.operation.path,
                                            callId: patchCall.resolvedCallId
                                        )
                                    ))

                                case let .mcpApprovalRequest(approvalRequest):
                                    let approvalResponse = Response.Input.Element.mcpApprovalResponse(
                                        Response.Input.MCPApprovalResponseInput(
                                            approve: true,
                                            approvalRequestId: approvalRequest.id
                                        )
                                    )
                                    _ = approvalResponse

                                default:
                                    break
                            }

                        case let .responseCompleted(response):
                            completedResponse = response
                            responseSpan.spanData = ResponseSpanData(response: response, input: currentInput)

                        case let .responseFailed(response):
                            responseSpan.spanData = ResponseSpanData(response: response, input: currentInput)
                            if let error = response.error {
                                throw APIError.apiError(error.message)
                            }

                        default:
                            break
                    }
                }
            }

            previousResponseId = completedResponse?.id
            resultRef.lastResponseId = previousResponseId

            // Extract apply_patch calls from the completed response (streaming deltas may be incomplete)
            if let response = completedResponse {
                for outputItem in response.output {
                    if case let .applyPatchCall(patchCall) = outputItem {
                        applyPatchCalls.append(patchCall)
                    }
                }
            }

            // Check for handoffs in function calls
            for functionCall in functionCalls {
                if let handoff = agent.handoffs.first(where: { $0.toolName == functionCall.name }),
                    let targetAgent = handoff.targetAgent {
                    // Execute handoff callback
                    do {
                        if handoff.inputType.self == Void.self {
                            try await handoff.callPerform(input: ())
                        } else if let payload = functionCall.arguments.data(using: .utf8),
                            let codableType = handoff.inputType as? Decodable.Type {
                            let typedInput = try JSONDecoder().decode(codableType, from: payload)
                            try await handoff.callPerform(input: typedInput)
                        }
                    } catch {
                        // Continue on handoff error
                    }

                    try await withSpan { span in
                        span.spanData = HandoffSpanData(fromAgent: agent.name, toAgent: targetAgent.name)
                    }

                    continuation.yield(.runItemEvent(
                        name: .handoffRequested,
                        item: .message("Handoff to \(targetAgent.name)")
                    ))

                    return .handOff(targetAgent)
                }
            }

            // Execute tool calls
            let toolOnlyCalls = functionCalls.filter { functionCall in
                !agent.handoffs.contains(where: { $0.toolName == functionCall.name })
            }

            // Collect all tool results
            var allResults = [Response.Input.Element]()

            if !toolOnlyCalls.isEmpty {
                let results = try await agent.executeToolCalls(toolOnlyCalls)

                for result in results {
                    if case let .functionCallOutput(output) = result {
                        continuation.yield(.runItemEvent(
                            name: .toolOutput,
                            item: .toolOutput(callId: output.callId, output: output.output)
                        ))
                    }
                }

                allResults.append(contentsOf: results)
            }

            // Process apply_patch calls
            for patchCall in applyPatchCalls {
                let output = executeApplyPatch(patchCall, agent: agent)
                continuation.yield(.runItemEvent(
                    name: .toolOutput,
                    item: .toolOutput(callId: patchCall.id, output: output.output)
                ))
                allResults.append(.applyPatchCallOutput(output))
            }

            if !allResults.isEmpty {
                currentInput = .array(allResults)
                try? await Task.sleep(nanoseconds: 200_000)
                continue
            }

            // No tool calls — this is the final output
            if A.OutputType.self == String.self {
                // swiftlint:disable:next force_cast - guarded above by `A.OutputType.self == String.self`.
                return .finalOutput(roundResult as! A.OutputType, roundReasoning)
            } else if let data = roundResult.data(using: .utf8) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let decoded = decoder.decodeWithResultsUnwrap(data, as: A.OutputType.self) {
                    return .finalOutput(decoded, roundReasoning)
                }
            }

            // Invalid response, try again
        }

        throw RunnerError.exceededMaxTurns
    }
}
