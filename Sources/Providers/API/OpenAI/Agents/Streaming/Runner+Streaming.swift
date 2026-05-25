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
    /// - Note: For OpenAI-backed models we use the Responses streaming API.
    ///   For providers that only expose the chat-completion shape (Anthropic,
    ///   LM Studio, OpenAI-compatible endpoints, etc.) we stream via
    ///   `api.createChatCompletionStream` and translate per-chunk deltas into
    ///   `outputTextDelta` / `runItemEvent` events. Providers whose streaming
    ///   isn't wired up yet fall back to non-streaming `Runner.run()` and emit
    ///   the final output as a single event.
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
                // Only finish the stream once `_runStreamedLoop` has fully
                // returned, which means the surrounding `withTrace` has
                // already flushed its spans via onTraceEnd. If we finished
                // earlier, the consumer's `for await ... in result.events`
                // loop could exit (and the test process could terminate)
                // while the BatchTraceProcessor is still mid-upload.
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
                throw error
            }
        }

        resultRef.task = task
        return resultRef
    }

    // MARK: - Internal Streaming Loop

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
            let modelSpec = config.model ?? agent.model ?? "gpt-4.1"
            let workflowName = Runner.workflowName(
                base: config.workFlowName,
                modelSpec: modelSpec
            )
            return try await withTrace(name: workflowName) {
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
            let modelSpec = config.model ?? currentAgent.model ?? "gpt-4.1"
            let api = try await Providers.shared.api(for: modelSpec)
            let model = modelSpec.modelNameWithoutProviderPrefix

            // Only api.openai.com speaks the Responses streaming API the
            // Agents SDK consumes natively. OpenAI-compatible endpoints
            // (LM Studio, llama.cpp's openai server, etc.) get the
            // `OpenAI` class for convenience but only implement
            // `/v1/chat/completions` — route them through the
            // chat-completion streaming surface instead.
            guard let openAI = api as? OpenAI, openAI.endpointURL == URL.openAI else {
                let chatResult: AgentResult<A.OutputType> = try await withSpan { agentSpan in
                    var tools: [Tool] = currentAgent.createTools()

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

                            mcpListSpan.spanData = MCPListToolsSpanData(
                                server: serverName,
                                result: mcpTools.map(\.name)
                            )
                            return myTools
                        }
                    }

                    agentSpan.spanData = AgentSpanData(
                        name: currentAgent.name,
                        handoffs: currentAgent.handoffs.compactMap { $0.targetAgent?.name },
                        tools: tools.map(\.nameForAgentSpan),
                        outputType: currentAgent.outputTypeForAgentSpan
                    )

                    return try await _executeChatCompletionStreamedTurns(
                        agent: currentAgent,
                        tools: tools,
                        maxTurns: maxTurns,
                        model: model,
                        api: api,
                        input: input,
                        continuation: continuation
                    )
                }

                switch chatResult {
                    case .finalOutput:
                        return
                    case let .handOff(nextAgent):
                        if let nextAgentTyped = nextAgent as? A {
                            currentAgent = nextAgentTyped
                            continuation.yield(.agentUpdated(name: currentAgent.name))
                            continue
                        } else {
                            throw RunnerError.exceededMaxTurns
                        }
                }
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
                                        item: .toolCall(
                                            name: functionCall.name,
                                            arguments: functionCall.arguments,
                                            callId: functionCall.callId
                                        )
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

    // MARK: - Chat Completion Streamed Turn Execution

    /// Streams an agent turn against providers that only expose the
    /// chat-completion shape (Anthropic, OpenAI-compatible local servers,
    /// etc.). Walks `Chunk` deltas and emits the same `AgentStreamEvent`
    /// surface as the Responses path so consumers don't need to branch on
    /// provider.
    ///
    /// If `api.createChatCompletionStream` reports the provider doesn't
    /// support streaming yet, we degrade to one synthetic event at the end
    /// — matching the prior behaviour for those providers.
    private static func _executeChatCompletionStreamedTurns<A: Agent>(
        agent: A,
        tools: [Tool],
        maxTurns: Int,
        model: String,
        api: API,
        input: String,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws -> AgentResult<A.OutputType> {
        var chatHistory: [ChatMessage] = [
            ChatMessage(role: .system, content: .text(agent.instructions)),
            ChatMessage(role: .user, content: .text(input))
        ]
        var turns = 0

        while turns < maxTurns {
            turns += 1

            try Task.checkCancellation()

            var roundResult = ""
            var assembledMessage: ChatMessage?

            try await withSpan { resultSpan in
                let stream: AsyncThrowingStream<Chunk, Error>
                do {
                    stream = try await api.createChatCompletionStream(
                        model: model,
                        messages: chatHistory,
                        tools: tools.toolDescriptions,
                        toolChoice: agent.modelSettings.toolChoice,
                        n: 1,
                        streamOptions: nil,
                        stop: nil,
                        store: agent.modelSettings.store,
                        temperature: agent.modelSettings.temperature,
                        maxCompletionTokens: agent.modelSettings.maxCompletionTokens,
                        metadata: agent.modelSettings.metadata,
                        parallelToolCalls: agent.modelSettings.parallelToolCalls,
                        presencePenalty: agent.modelSettings.presencePenalty ?? 0.0,
                        responseFormat: agent.responseFormat,
                        frequencyPenalty: agent.modelSettings.frequencyPenalty ?? 0.0,
                        logitBias: nil,
                        user: nil
                    )
                } catch let APIError.otherError(code, _) where code == "unsupported" {
                    // Provider hasn't wired up chat-completion streaming yet
                    // (e.g. Google as of writing). Fall back to a single
                    // non-streaming call so the run still produces an output.
                    let completion = try await api.createChatCompletion(
                        model: model,
                        messages: chatHistory,
                        tools: tools.toolDescriptions,
                        n: nil,
                        stop: nil,
                        store: agent.modelSettings.store,
                        temperature: agent.modelSettings.temperature,
                        maxCompletionTokens: agent.modelSettings.maxCompletionTokens,
                        metadata: agent.modelSettings.metadata,
                        presencePenalty: agent.modelSettings.presencePenalty,
                        responseFormat: agent.responseFormat,
                        frequencyPenalty: agent.modelSettings.frequencyPenalty,
                        logitBias: nil,
                        user: nil
                    )
                    if let choice = completion.choices.first {
                        assembledMessage = choice.message
                    }
                    Self.recordGenerationSpan(
                        span: resultSpan,
                        chatHistory: chatHistory,
                        completion: completion,
                        model: model,
                        agent: agent,
                        api: api
                    )
                    return
                }

                let assembler = ChatCompletionAssembler()

                for try await chunk in stream {
                    assembler.processChunk(chunk)

                    for choice in chunk.choices {
                        if let textDelta = choice.delta.content, !textDelta.isEmpty {
                            let info = ResponsesStreamEvent.OutputTextDeltaInfo(
                                itemId: chunk.id,
                                outputIndex: choice.index,
                                contentIndex: 0,
                                delta: textDelta
                            )
                            continuation.yield(.rawResponseEvent(ResponsesStreamEvent(
                                type: "response.output_text.delta",
                                object: .outputTextDelta(info)
                            )))
                        }

                        for toolDelta in choice.delta.toolCalls ?? [] {
                            if let json = toolDelta.function?.arguments, !json.isEmpty {
                                let info = ResponsesStreamEvent.FunctionCallArgumentsDeltaInfo(
                                    itemId: toolDelta.id ?? chunk.id,
                                    outputIndex: toolDelta.index ?? 0,
                                    delta: json
                                )
                                continuation.yield(.rawResponseEvent(ResponsesStreamEvent(
                                    type: "response.function_call_arguments.delta",
                                    object: .functionCallArgumentsDelta(info)
                                )))
                            }
                        }
                    }
                }

                let response = assembler.response
                if let choice = response.choices.first {
                    assembledMessage = choice.message
                }
                Self.recordGenerationSpan(
                    span: resultSpan,
                    chatHistory: chatHistory,
                    completion: response,
                    model: model,
                    agent: agent,
                    api: api
                )
            }

            guard let message = assembledMessage else {
                throw APIError.apiError("Empty chat completion stream")
            }

            chatHistory.append(message)

            // Collect any tool calls the assistant made this turn and translate
            // them into the Responses-shaped `OutputItem.FunctionCall` the rest
            // of the runner machinery already understands.
            var functionCalls: [OutputItem.FunctionCall] = []
            if let toolCalls = message.toolCalls {
                for call in toolCalls {
                    let name = call.function?.name ?? ""
                    let arguments = call.function?.arguments ?? ""
                    functionCalls.append(OutputItem.FunctionCall(
                        id: call.id,
                        callId: call.id,
                        name: name,
                        arguments: arguments,
                        status: .completed
                    ))
                    continuation.yield(.runItemEvent(
                        name: .toolCalled,
                        item: .toolCall(name: name, arguments: arguments, callId: call.id)
                    ))
                }
            }

            // Check for handoffs
            for functionCall in functionCalls {
                if let handoff = agent.handoffs.first(where: { $0.toolName == functionCall.name }),
                    let targetAgent = handoff.targetAgent {
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

            let toolOnlyCalls = functionCalls.filter { call in
                !agent.handoffs.contains(where: { $0.toolName == call.name })
            }

            if !toolOnlyCalls.isEmpty {
                let results = try await agent.executeToolCalls(toolOnlyCalls)
                for result in results {
                    if case let .functionCallOutput(output) = result {
                        continuation.yield(.runItemEvent(
                            name: .toolOutput,
                            item: .toolOutput(callId: output.callId, output: output.output)
                        ))
                        chatHistory.append(ChatMessage(
                            role: .tool,
                            content: .text(output.output),
                            toolCallID: output.callId
                        ))
                    }
                }
                // Loop again to give the model the tool results.
                continue
            }

            // No tool calls — this is the final output for this agent.
            if let text = message.textContent {
                roundResult = text
            }

            if !roundResult.isEmpty {
                continuation.yield(.runItemEvent(
                    name: .messageOutputCreated,
                    item: .message(roundResult)
                ))
            }

            if A.OutputType.self == String.self {
                // swiftlint:disable:next force_cast - guarded above by `A.OutputType.self == String.self`.
                return .finalOutput(roundResult as! A.OutputType, nil)
            } else if let data = roundResult.data(using: .utf8) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let decoded = decoder.decodeWithResultsUnwrap(data, as: A.OutputType.self) {
                    return .finalOutput(decoded, nil)
                }
            }

            // Invalid response, try again
        }

        throw RunnerError.exceededMaxTurns
    }

    /// Builds `GenerationSpanData` from a fully-assembled chat completion and
    /// stores it on the current response span. Mirrors the dictionary shape
    /// used by `Runner.executeAgentTurns`'s non-streaming chat path so traces
    /// look the same regardless of provider or stream mode.
    private static func recordGenerationSpan<A: Agent>(
        span: TraceSpan,
        chatHistory: [ChatMessage],
        completion: ChatCompletionResponse,
        model: String,
        agent: A,
        api: API
    ) {
        let inputMessages: [[String: JSONValue]] = chatHistory.map { msg in
            var dict: [String: JSONValue] = ["role": JSONValue(msg.role.rawValue)]
            if let content = msg.content {
                switch content {
                    case let .text(text):
                        if !text.isEmpty { dict["content"] = JSONValue(text) }
                    case let .parts(parts):
                        let text = ChatMessage.ContentPart.textParts(from: parts).joined(separator: "\n")
                        if !text.isEmpty { dict["content"] = JSONValue(text) }
                }
            }
            if let toolCalls = msg.toolCalls {
                dict["tool_calls"] = JSONValue(toolCalls.map { call -> [String: JSONValue] in
                    [
                        "id": JSONValue(call.id),
                        "type": JSONValue("function"),
                        "function": JSONValue([
                            "name": JSONValue(call.function?.name ?? ""),
                            "arguments": JSONValue(call.function?.arguments ?? "")
                        ])
                    ]
                })
            }
            if let toolCallID = msg.toolCallID {
                dict["tool_call_id"] = JSONValue(toolCallID)
            }
            return dict
        }

        let outputMessages: [[String: JSONValue]] = completion.choices.flatMap { choice -> [[String: JSONValue]] in
            var entries: [[String: JSONValue]] = []
            if let text = choice.message.textContent, !text.isEmpty {
                entries.append([
                    "type": JSONValue("message"),
                    "role": JSONValue(choice.message.role.rawValue),
                    "content": JSONValue(text)
                ])
            }
            for call in choice.message.toolCalls ?? [] {
                entries.append([
                    "type": JSONValue("tool_call"),
                    "tool_call_id": JSONValue(call.id),
                    "tool_name": JSONValue(call.function?.name ?? ""),
                    "arguments": JSONValue(call.function?.arguments ?? "")
                ])
            }
            return entries
        }

        let modelConfig: [String: JSONValue] = [
            "temperature": JSONValue(agent.modelSettings.temperature),
            "top_p": JSONValue(agent.modelSettings.topP),
            "frequency_penalty": JSONValue(agent.modelSettings.frequencyPenalty),
            "presence_penalty": JSONValue(agent.modelSettings.presencePenalty),
            "tool_choice": JSONValue(agent.modelSettings.toolChoice),
            "parallel_tool_calls": JSONValue(agent.modelSettings.parallelToolCalls),
            "truncation": JSONValue(agent.modelSettings.truncation),
            "max_tokens": JSONValue(agent.modelSettings.maxCompletionTokens),
            "reasoning": JSONValue(agent.modelSettings.reasoning),
            "metadata": JSONValue(agent.modelSettings.metadata),
            "store": JSONValue(agent.modelSettings.store),
            "include_usage": JSONValue(agent.modelSettings.includeUsage),
            "extra_query": JSONValue(agent.modelSettings.extraQuery),
            "extra_body": JSONValue(agent.modelSettings.extraBody),
            "extra_headers": JSONValue(agent.modelSettings.extraHeaders),
            "base_url": JSONValue(agent.modelSettings.baseURL ?? api.endpointURL.absoluteString)
        ]

        let usage: [String: JSONValue] = [
            "input_tokens": JSONValue(completion.usage?.promptTokens ?? 0),
            "output_tokens": JSONValue(completion.usage?.completionTokens ?? 0)
        ]

        span.spanData = GenerationSpanData(
            input: inputMessages,
            output: outputMessages,
            model: model,
            modelConfig: modelConfig,
            usage: usage
        )
    }
}
