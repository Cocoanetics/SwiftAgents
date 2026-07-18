import Foundation
import Providers
import Tracing

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

        // Build the run-configured decoder once (mirroring the non-streaming
        // loop) so typed final outputs and typed handoff inputs honor
        // `RunConfig.dateDecodingStrategy`.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = config.dateDecodingStrategy

        var currentAgent: A = agent
        // Chat history accumulates across handoffs on the chat-completion
        // fallback path so the receiving agent sees the prior agent's
        // assistant message + the handoff tool result instead of restarting
        // from the original user input.
        var chatHistory: [ChatMessage] = []

        repeat {
            let modelSpec = config.model ?? currentAgent.model ?? "gpt-4.1"
            // An explicit `config.api` (e.g. a per-session
            // `OpenAIResponsesWebSocket`) wins over provider-name routing —
            // mirroring the non-streaming loop. The injected client flows
            // through the same OpenAI-vs-chat gate below.
            let api: API
            if let injected = config.api {
                api = injected
            } else {
                api = try await ProviderRegistry.shared.api(for: modelSpec)
            }
            let model = modelSpec.modelNameWithoutProviderPrefix

            // Use the Responses streaming API only when the provider opts in via
            // `prefersResponsesStreaming` (first-party OpenAI, LM Studio, and the
            // ChatGPT Codex backend). Server-side history is NOT required — a
            // stateless Responses backend (Codex) streams here too, with the
            // turn loop resending the full accumulated input instead of chaining
            // `previous_response_id`. Structured-output turns fall back to
            // chat-completion streaming on providers whose Responses endpoint
            // ignores the schema (LM Studio), so `response_format` still
            // constrains the model — mirroring the non-streaming gate. Chat-only
            // OpenAI-compat servers (e.g. llama.cpp) stream via `/v1/chat/completions`.
            guard let openAI = api as? OpenAI,
                  openAI.prefersResponsesStreaming,
                  Self.shouldStreamViaResponses(policy: api.statePolicy, outputType: currentAgent.outputType)
            else {
                // Media output (image/audio) can't be streamed token-wise on the
                // chat-completion path, and there's no stream event to carry the
                // bytes — fail fast with guidance instead of looping to maxTurns.
                // (OpenAI's Responses path streams images natively, above.)
                let requestedMedia = config.requestedMedia ?? (currentAgent as? RequestsMedia)?.requestedMedia ?? []
                guard requestedMedia.isEmpty else { throw RunnerError.mediaOutputNotStreamable }

                let chatResult: AgentResult<A.OutputType> = try await withSpan { agentSpan in
                    var tools: [Tool] = await currentAgent.createTools()
                    tools += try await Self.collectMCPTools(for: currentAgent)

                    agentSpan.spanData = AgentSpanData(
                        name: currentAgent.name,
                        handoffs: currentAgent.handoffs.compactMap { $0.targetAgent?.name },
                        tools: tools.map(\.nameForAgentSpan),
                        outputType: currentAgent.outputTypeForAgentSpan
                    )

                    return try await executeChatCompletionStreamedTurns(
                        agent: currentAgent,
                        tools: tools,
                        maxTurns: maxTurns,
                        model: model,
                        api: api,
                        input: input,
                        chatHistory: &chatHistory,
                        decoder: decoder,
                        continuation: continuation
                    )
                }

                switch chatResult {
                    case .finalOutput:
                        return
                    case let .handOff(nextAgent):
                        if let nextAgentTyped = nextAgent as? A {
                            currentAgent = nextAgentTyped
                            // Swap the system prompt in place so the new
                            // agent sees its own instructions while keeping
                            // the rest of the conversation (user input,
                            // prior assistant turn, handoff tool result).
                            if let first = chatHistory.first, first.role == .system {
                                chatHistory[0] = ChatMessage(
                                    role: .system,
                                    content: .text(currentAgent.instructions)
                                )
                            }
                            continuation.yield(.agentUpdated(name: currentAgent.name))
                            continue
                        } else {
                            throw RunnerError.exceededMaxTurns
                        }
                }
            }

            let result: AgentResult<A.OutputType> = try await withSpan { agentSpan in
                var tools: [Tool] = await currentAgent.createTools()
                tools += try await Self.collectMCPTools(for: currentAgent)

                // Realize an image intent as the OpenAI image_generation tool
                // (this branch is the OpenAI Responses streaming path).
                let requestedMedia = config.requestedMedia ?? (currentAgent as? RequestsMedia)?.requestedMedia ?? []
                tools = Self.realizingImageTool(tools, for: requestedMedia, api: api)

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
                    decoder: decoder,
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

    /// Span data for a streamed stateful turn: a `ResponseSpanData` when the
    /// provider's response id is OpenAI-routable, otherwise a `GenerationSpanData`
    /// carrying the full input/output (so non-routable providers like LM Studio
    /// render in tracing without an OpenAI lookup) — mirroring the non-streaming
    /// Runner and the chat-completions path.
    private static func streamedResponseSpanData(
        openAI: OpenAI,
        response: Response,
        input: Response.Input,
        instructions: String?,
        model: String,
        modelSettings: ModelSettings
    ) -> SpanData {
        if openAI.statePolicy.responseIdsAreOpenAIRoutable {
            return ResponseSpanData(response: response, input: input)
        }
        return makeGenerationSpanForResponse(
            input: input,
            instructions: instructions,
            response: response,
            model: model,
            modelSettings: modelSettings,
            baseURL: openAI.endpointURL.absoluteString
        )
    }

    private static func _executeStreamedTurns<A: Agent>(
        agent: A,
        agentSpan _: TraceSpan,
        tools: [Tool],
        maxTurns: Int,
        model: String,
        openAI: OpenAI,
        input: Response.Input,
        previousResponseId: String?,
        decoder: JSONDecoder,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        resultRef: RunResultStreaming
    ) async throws -> AgentResult<A.OutputType> {
        // Stateless Responses backends (`supportsServerSideHistory == false`,
        // e.g. the ChatGPT Codex backend) never persist responses: `store` is
        // forced false, `previous_response_id` can never resolve, and the
        // instructions must ride along on every turn. The loop keeps the full
        // conversation locally instead — the initial input items plus, after
        // each turn, the response's output items (reasoning included: the
        // Responses API rejects a resent function_call whose preceding
        // reasoning item is missing) and the tool outputs.
        let serverKeepsHistory = openAI.statePolicy.supportsServerSideHistory
        var accumulatedInput: [Response.Input.Element]
        switch input {
            case let .text(text):
                accumulatedInput = [.userMessage(text)]
            case let .array(elements):
                accumulatedInput = elements
        }

        var currentInput = serverKeepsHistory ? input : .array(accumulatedInput)
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
            var roundFile: GeneratedFile?

            try await withSpan { responseSpan in
                // Placeholder span before the call. Only OpenAI-routable providers
                // get a ResponseSpanData (its id resolves in OpenAI tracing); for
                // others (e.g. LM Studio) a GenerationSpanData carrying the full
                // payload is filled in once the response completes, below.
                if openAI.statePolicy.responseIdsAreOpenAIRoutable {
                    responseSpan.spanData = ResponseSpanData(input: currentInput)
                }

                // When continuing a conversation, skip instructions — the API has
                // them via previousResponseId. Stateless backends have no
                // server-side context, so they get the instructions every turn.
                let instructions = (serverKeepsHistory && previousResponseId != nil) ? nil : agent.instructions

                // A WebSocket-backed client streams the turn over its persistent
                // socket (same `ResponsesStreamEvent` shape); everyone else uses
                // the HTTP SSE create-stream. Both yield identical events, so the
                // consumer loop below is unchanged.
                let stream: AsyncThrowingStream<ResponsesStreamEvent, Error>
                if let webSocket = openAI as? OpenAIResponsesWebSocket {
                    stream = webSocket.streamResponse(
                        input: currentInput,
                        model: model,
                        instructions: instructions,
                        previousResponseId: previousResponseId,
                        tools: tools,
                        modelSettings: agent.modelSettings
                    )
                } else {
                    stream = try await openAI.createResponseStream(
                        input: currentInput,
                        model: model,
                        // Stateless backends must return the encrypted
                        // reasoning payload so it can be replayed as input.
                        include: serverKeepsHistory ? nil : [.reasoningEncryptedContent],
                        instructions: instructions,
                        maxOutputTokens: agent.modelSettings.maxCompletionTokens,
                        metadata: agent.modelSettings.metadata,
                        parallelToolCalls: agent.modelSettings.parallelToolCalls,
                        previousResponseId: serverKeepsHistory ? previousResponseId : nil,
                        reasoning: agent.modelSettings.reasoning,
                        store: serverKeepsHistory ? agent.modelSettings.store : false,
                        temperature: agent.modelSettings.temperature,
                        toolChoice: agent.modelSettings.toolChoice,
                        tools: tools,
                        topP: agent.modelSettings.topP,
                        truncation: agent.modelSettings.truncation
                    )
                }

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
                            responseSpan.spanData = Self.streamedResponseSpanData(
                                openAI: openAI, response: response, input: currentInput,
                                instructions: instructions, model: model,
                                modelSettings: agent.modelSettings
                            )

                        case let .responseFailed(response):
                            responseSpan.spanData = Self.streamedResponseSpanData(
                                openAI: openAI, response: response, input: currentInput,
                                instructions: instructions, model: model,
                                modelSettings: agent.modelSettings
                            )
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

            // Stateless backends: fold this turn's output into the locally
            // accumulated conversation so the next request resends everything
            // (reasoning items included, encrypted content and all).
            if !serverKeepsHistory, let response = completedResponse {
                accumulatedInput.append(contentsOf: response.output.compactMap {
                    $0.toInputElement(preservingReasoning: true)
                })
            }

            // Extract apply_patch calls and any generated image from the
            // completed response — the streaming deltas may be incomplete, but
            // the final response carries the full output items.
            if let response = completedResponse {
                for outputItem in response.output {
                    if case let .applyPatchCall(patchCall) = outputItem {
                        applyPatchCalls.append(patchCall)
                    }
                    if case let .imageGenerationCall(imageCall) = outputItem, let bytes = imageCall.result {
                        roundFile = GeneratedFile(data: bytes, mimeType: imageCall.mimeType, id: imageCall.id)
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
                            let typedInput = try decoder.decode(codableType, from: payload)
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
                if serverKeepsHistory {
                    // The server holds the prior turns — send only the delta.
                    currentInput = .array(allResults)
                } else {
                    // No server-side state — resend the whole conversation.
                    accumulatedInput.append(contentsOf: allResults)
                    currentInput = .array(accumulatedInput)
                }
                try? await Task.sleep(nanoseconds: 200_000)
                continue
            }

            // No tool calls — resolve the turn into a typed final output;
            // `nil` means the response wasn't usable, so repeat the turn.
            if let result = Self.terminalOutput(
                for: A.self, text: roundResult, file: roundFile,
                reasoning: roundReasoning, decoder: decoder
            ) {
                return result
            }

            // Invalid response, try again
        }

        throw RunnerError.exceededMaxTurns
    }
}
