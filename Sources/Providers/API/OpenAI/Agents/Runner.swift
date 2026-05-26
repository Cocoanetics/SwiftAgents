import Foundation
import SwiftMCP

private let agentLogsEnabled = ProcessInfo.processInfo.environment["AGENT_LOGS"] != nil

@inline(__always)
private func logAgent(_ message: @autoclosure () -> String) {
    guard agentLogsEnabled else { return }
    NSLog("%@", message())
}

/// Enum to represent outcomes from the task group for guardrails
private enum GuardrailOutcome<OutputType: Sendable> {
    case agent(AgentResult<OutputType>)
    case guardrail(name: String, result: InputGuardrailResult)
    case taskError(Error)
}

/** Main runner for executing agent workflows
 
 This struct handles the execution of agent workflows, managing the interaction
 between agents, tools, and the OpenAI API.
 */
public actor Runner {
    /// Run an agent workflow. Mirrors `openai-agents-python`'s
    /// `Runner.run(...)` surface, in Swift naming:
    ///   - `session`: provider-agnostic conversation log. When passed,
    ///     `conversationId`/`previousResponseId`/`autoPreviousResponseId`
    ///     must all be unset — they're alternative ways to track the same
    ///     conversation and combining them double-counts items.
    ///   - `previousResponseId`: chain pointer for stateful providers
    ///     (OpenAI Responses API, LM Studio native chat).
    ///   - `autoPreviousResponseId`: round-trip flag carried back on
    ///     `RunResult` so callers can opt into chain continuity without
    ///     juggling ids by hand.
    ///   - `conversationId`: OpenAI Conversations API handle. The server
    ///     becomes the source of truth; we forward it to `createResponse`
    ///     and let it manage history.
    public static func run<A: Agent>(
        agent: A,
        input: String,
        session: Session? = nil,
        previousResponseId: String? = nil,
        autoPreviousResponseId: Bool = false,
        conversationId: String? = nil,
        maxTurns: Int = 10,
        config: RunConfig = RunConfig()
    ) async throws -> RunResult<A.OutputType> {
        // Plain-text convenience — defers to the multimodal entrypoint.
        try await run(
            agent: agent,
            input: Response.Input.text(input),
            session: session,
            previousResponseId: previousResponseId,
            autoPreviousResponseId: autoPreviousResponseId,
            conversationId: conversationId,
            maxTurns: maxTurns,
            config: config
        )
    }

    /// Multimodal entrypoint. Accepts `Response.Input` so callers can pass
    /// structured user input — e.g. a message with `.inputImage` content —
    /// alongside (or instead of) plain text. Mirrors Python's
    /// `Runner.run(input: str | list[TResponseInputItem])`.
    public static func run<A: Agent>(
        agent: A,
        input: Response.Input,
        session: Session? = nil,
        previousResponseId: String? = nil,
        autoPreviousResponseId: Bool = false,
        conversationId: String? = nil,
        maxTurns: Int = 10,
        config: RunConfig = RunConfig()
    ) async throws -> RunResult<A.OutputType> {
        try validateSessionConversationSettings(
            session: session,
            conversationId: conversationId,
            previousResponseId: previousResponseId,
            autoPreviousResponseId: autoPreviousResponseId
        )

        let decoder: JSONDecoder = .init()
        decoder.dateDecodingStrategy = config.dateDecodingStrategy

        if TraceContext.currentTrace == nil {
            // no current trace context, so we start one with a name derived
            // from the model spec when possible (main brought `workflowName`
            // in via the streaming PR).
            let spec = config.model ?? agent.model ?? "gpt-4.1"
            let name = Runner.workflowName(base: config.workFlowName, modelSpec: spec)
            return try await withTrace(name: name) {
                return try await run(
                    agent: agent,
                    input: input,
                    session: session,
                    previousResponseId: previousResponseId,
                    autoPreviousResponseId: autoPreviousResponseId,
                    conversationId: conversationId,
                    maxTurns: maxTurns,
                    config: config
                )
            }
        }

        // Provider-agnostic session is the canonical conversation log. If
        // the caller didn't pass one, we still use a fresh InMemorySession
        // internally so the per-turn flow stays uniform.
        let session: Session = session ?? InMemorySession()
        // Internal tracker, hydrated from the scalar kwargs. Mirrors
        // Python's OpenAIServerConversationTracker — not exposed to
        // callers; the resolved final values flow back via RunResult.
        let tracker = ConversationStateTracker(
            conversationId: conversationId,
            previousResponseId: previousResponseId
        )

        // Seed the session with the user input. `.text(s)` becomes a single
        // user message; `.array(items)` is appended verbatim so multimodal
        // callers can include `.inputImage` / `.inputImageFileID` parts.
        let seededItems: [Response.Input.Element] = switch input {
            case let .text(text): [.userMessage(text)]
            case let .array(elements): elements
        }
        try await session.addItems(seededItems)

        var turns = 0
        let nextInput = input

        var currentAgent: A = agent

        repeat {
            let modelSpec = config.model ?? currentAgent.model ?? "gpt-4.1"
            let api = try await Providers.shared.api(for: modelSpec)
            let model = modelSpec.modelNameWithoutProviderPrefix

            // Reset the per-agent nextInput pointer to the original user
            // input. The session and tracker carry forward unchanged across
            // handoffs.
            var currentNextInput = nextInput

            let agentResult: AgentResult<A.OutputType> = try await withSpan { agentSpan in
                var tools: [Tool] = currentAgent.createTools()
                tools += try await Self.collectMCPTools(for: currentAgent)

                agentSpan.spanData = AgentSpanData(
                    name: currentAgent.name,
                    handoffs: currentAgent.handoffs.compactMap { $0.targetAgent?.name },
                    tools: tools.map(\.nameForAgentSpan),
                    outputType: currentAgent.outputTypeForAgentSpan
                )

                // Check if we should run input guardrails (only for the first agent in a workflow)
                if !currentAgent.inputGuardrails.isEmpty, agentSpan.parentID == nil {
                    // Guardrails evaluate plain text — flatten any
                    // multimodal `Response.Input` to its text parts so
                    // guardrail signatures stay backwards-compatible.
                    let guardrailInput = Self.flattenInputText(input)
                    // Execute agent with guardrails in parallel
                    let result = try await executeWithInputGuardrails(
                        agent: currentAgent,
                        input: guardrailInput,
                        agentSpan: agentSpan,
                        tools: tools,
                        maxTurns: maxTurns,
                        model: model,
                        api: api,
                        nextInput: currentNextInput,
                        session: session,
                        tracker: tracker,
                        decoder: decoder,
                        config: config
                    )

                    // Update the current input pointer if needed; session
                    // and tracker mutate in place.
                    if case let .continueWithState(state) = result.continuation {
                        currentNextInput = state.nextInput
                    }

                    // Check output guardrails before returning the result from the agent's span
                    if case let .finalOutput(output, _) = result.result {
                        try await Runner.checkOutputGuardrails(
                            currentAgent.outputGuardrails + config.outputGuardrails,
                            output: output,
                            agent: currentAgent
                        )
                    }
                    return result.result
                } else {
                    // Execute the agent directly using the turnState to track nextInput
                    var turnState = TurnState(
                        nextInput: currentNextInput,
                        turns: turns
                    )

                    let result = try await executeAgentTurns(
                        agent: currentAgent,
                        agentSpan: agentSpan,
                        tools: tools,
                        maxTurns: maxTurns,
                        model: model,
                        api: api,
                        turnState: &turnState,
                        session: session,
                        tracker: tracker,
                        decoder: decoder
                    )

                    // Update outer variables with final turn state
                    turns = turnState.turns

                    // Check output guardrails before returning the result from the agent's span
                    if case let .finalOutput(output, _) = result {
                        let combinedOutputGuardrails = currentAgent.outputGuardrails + config.outputGuardrails
                        try await Runner.checkOutputGuardrails(
                            combinedOutputGuardrails,
                            output: output,
                            agent: currentAgent
                        )
                    }
                    return result
                }
            }

            switch agentResult {
                case let .finalOutput(output, reasoning):
                    // Pull the resolved chain pointers off the internal
                    // tracker so callers can resume by passing them back as
                    // `previousResponseId` / `conversationId` on the next
                    // `Runner.run` call. Mirrors Python's
                    // `RunResult._previous_response_id` / `_conversation_id`.
                    let resolvedResponseId = await tracker.previousResponseId
                    let resolvedConversationId = await tracker.conversationId
                    return RunResult(
                        finalOutput: output,
                        finalReasoning: reasoning,
                        lastResponseId: resolvedResponseId,
                        lastConversationId: resolvedConversationId,
                        autoPreviousResponseId: autoPreviousResponseId
                    )
                case let .handOff(nextAgent):
                    if let nextAgentTyped = nextAgent as? A {
                        currentAgent = nextAgentTyped
                    } else {
                        // This shouldn't happen - but we need to handle it to satisfy the compiler
                        // The most reasonable thing to do is just terminate with an error
                        throw RunnerError.exceededMaxTurns
                    }
            }
        } while true
    }

    // MARK: - Helpers

    /// Per-turn scratch state. Conversation history lives on the `Session`;
    /// chain id lives on the `ConversationStateTracker`. This struct just
    /// carries the bits that change between agents during a single run
    /// (the next input to send + a turn counter).
    private struct TurnState {
        var nextInput: Response.Input
        var turns: Int
    }

    /// Result type for the executeWithInputGuardrails function to include continuation state
    private struct GuardrailExecutionResult<T> {
        let result: AgentResult<T>
        let continuation: ContinuationState

        enum ContinuationState {
            case completed
            case continueWithState(state: TurnState)
        }
    }

    // Helper function for executing an agent with input guardrails
    private static func executeWithInputGuardrails<A: Agent>(
        agent: A,
        input: String,
        agentSpan: TraceSpan,
        tools: [Tool],
        maxTurns: Int,
        model: String,
        api: API,
        nextInput: Response.Input,
        session: Session,
        tracker: ConversationStateTracker,
        decoder: JSONDecoder,
        config: RunConfig
    ) async throws -> GuardrailExecutionResult<A.OutputType> {
        // Initialize turn state
        var turnState = TurnState(
            nextInput: nextInput,
            turns: 0
        )

        // Track if the agent finished before any guardrail
        var agentFinishedFirst = false
        var guardrailResults: [(name: String, result: InputGuardrailResult)] = []
        var storedAgentResult: AgentResult<A.OutputType>?
        var firstEncounteredError: Error?

        return try await withThrowingTaskGroup(of: GuardrailOutcome<A.OutputType>.self) { group in
            // Start agent task
            group.addTask {
                do {
                    let result = try await executeAgentTurns(
                        agent: agent,
                        agentSpan: agentSpan,
                        tools: tools,
                        maxTurns: maxTurns,
                        model: model,
                        api: api,
                        turnState: &turnState,
                        session: session,
                        tracker: tracker,
                        decoder: decoder
                    )
                    return .agent(result)
                } catch {
                    return .taskError(error)
                }
            }

            // Start each guardrail task
            for inputGuardrail in agent.inputGuardrails + config.inputGuardrails {
                group.addTask {
                    do {
                        // Use withSpan for the guardrail evaluation
                        let evaluationResult = try await withSpan { span in
                            let result = try await inputGuardrail.evaluate(input)
                            span.spanData = GuardrailSpanData(
                                name: inputGuardrail.name,
                                triggered: result.tripwireTriggered
                            )
                            return result
                        }
                        return .guardrail(name: inputGuardrail.name, result: evaluationResult)
                    } catch {
                        // If withSpan or evaluate throws, record the error and propagate
                        TraceContext.currentSpan?.spanData = GuardrailSpanData(
                            name: inputGuardrail.name,
                            triggered: false
                        )
                        return .taskError(error)
                    }
                }
            }

            var triggeredGuardrailError: Error?

            // Process results from tasks
            while let outcome = await group.nextResult() {
                switch outcome {
                    case let .success(guardrailOutcome):
                        switch guardrailOutcome {
                            case let .agent(result):
                                if triggeredGuardrailError == nil {
                                    storedAgentResult = result
                                    agentFinishedFirst = true
                                }
                            case let .guardrail(name, gResult):
                                guardrailResults.append((name, gResult))
                                if gResult.tripwireTriggered, triggeredGuardrailError == nil {
                                    // First guardrail to trigger
                                    triggeredGuardrailError = InputGuardrailTripwireTriggered(
                                        guardrailName: name,
                                        result: gResult
                                    )
                                    group.cancelAll() // Cancel other tasks
                                }
                            case let .taskError(err):
                                if triggeredGuardrailError == nil, firstEncounteredError == nil {
                                    firstEncounteredError = err
                                }
                        }
                    case let .failure(error):
                        if triggeredGuardrailError == nil, firstEncounteredError == nil {
                            firstEncounteredError = error
                        }
                }
            }

            // If the agent finished first, but a guardrail result triggered later, throw the guardrail error
            if agentFinishedFirst {
                if let tripped = guardrailResults.first(where: { $0.result.tripwireTriggered }) {
                    throw InputGuardrailTripwireTriggered(
                        guardrailName: tripped.name,
                        result: tripped.result
                    )
                }
            }

            // Prioritize throwing the specific guardrail tripwire error
            if let specificError = triggeredGuardrailError as? InputGuardrailTripwireTriggered {
                throw specificError
            }

            // If a guardrail didn't trigger, but an agent or guardrail task failed, throw that error
            if let errorToThrow = firstEncounteredError {
                throw errorToThrow
            }

            // If agent completed successfully and no guardrail triggered, return the stored result
            if let result = storedAgentResult {
                return GuardrailExecutionResult(
                    result: result,
                    continuation: .continueWithState(state: turnState)
                )
            }

            // This should not be reached if logic is sound
            throw CancellationError()
        }
    }

    // Helper function for executing agent turns
    private static func executeAgentTurns<A: Agent>(
        agent: A,
        agentSpan _: TraceSpan,
        tools: [Tool],
        maxTurns: Int,
        model: String,
        api: API,
        turnState: inout TurnState,
        session: Session,
        tracker: ConversationStateTracker,
        decoder: JSONDecoder
    ) async throws -> AgentResult<A.OutputType> {
        while turnState.turns < maxTurns {
            turnState.turns += 1

            // Improved logging: agent name, model, turn number
            logAgent("[Agent: \(agent.name)] [Model: \(model)] Starting turn \(turnState.turns)")

            var roundResult = ""
            var roundReasoning: String?

            do {
                let response: Response

                let useStatefulPath = Self.shouldUseStatefulPath(
                    policy: api.statePolicy,
                    outputType: agent.outputType
                )
                if useStatefulPath, let stateful = api as? ServerHistoryAPI {
                    response = try await withSpan { resultSpan in
                        // Placeholder span before the call so error paths
                        // still record something. For OpenAI-routable
                        // providers we use ResponseSpanData (carries the id
                        // OpenAI trace can resolve); for others we'll fill
                        // a GenerationSpanData below.
                        if api.statePolicy.responseIdsAreOpenAIRoutable {
                            resultSpan.spanData = ResponseSpanData(input: turnState.nextInput)
                        }

                        let previousResponseId = await tracker.previousResponseId
                        let conversationId = await tracker.conversationId

                        // When the chain pointer or conversation handle is
                        // present, the server already has prior context;
                        // send only the new turn. Otherwise (fresh run, or
                        // resumed via a Session that wasn't paired with a
                        // chain id), pass the full session history so the
                        // server can reconstruct the conversation.
                        let stateLessInput: Response.Input
                        if previousResponseId != nil || conversationId != nil {
                            stateLessInput = turnState.nextInput
                        } else {
                            let sessionItems = try await session.getItems()
                            stateLessInput = sessionItems.isEmpty
                                ? turnState.nextInput
                                : .array(sessionItems)
                        }

                        let response = try await stateful.dispatchCreateResponse(
                            input: stateLessInput,
                            model: model,
                            instructions: agent.instructions,
                            previousResponseId: previousResponseId,
                            conversationId: conversationId,
                            textFormat: agent.outputType,
                            tools: tools,
                            modelSettings: agent.modelSettings
                        )

                        if api.statePolicy.responseIdsAreOpenAIRoutable {
                            resultSpan.spanData = ResponseSpanData(response: response, input: turnState.nextInput)
                        } else {
                            // Foreign response id — synthesise a Generation
                            // span carrying the full session history (not
                            // just the per-turn delta) so the dashboard
                            // shows what the model actually saw.
                            resultSpan.spanData = try await Self.makeGenerationSpanForResponse(
                                session: session,
                                fallback: turnState.nextInput,
                                instructions: agent.instructions,
                                response: response,
                                model: model,
                                modelSettings: agent.modelSettings,
                                baseURL: api.endpointURL.absoluteString
                            )
                        }
                        return response
                    }
                } else {
                    // Fallback for APIs that only support chat completion style.
                    // Build the wire history from the session each turn so a
                    // resumed session picks up its prior messages, then
                    // prepend the agent's system instructions.
                    response = try await withSpan { resultSpan in
                        let sessionItems = try await session.getItems()
                        var messages: [ChatMessage] = [
                            ChatMessage(role: .system, content: .text(agent.instructions))
                        ]
                        messages.append(contentsOf: Response.Input.array(sessionItems).toChatMessage())

                        // Call chat completion on generic API. Send `nil`
                        // for `tools` when there aren't any — LM Studio
                        // treats an empty `tools: []` as "enable lazy
                        // grammar," which conflicts with structured-output
                        // constraints.
                        let chatTools = tools.toolDescriptions
                        let completion = try await api.createChatCompletion(
                            model: model,
                            messages: messages,
                            tools: chatTools.isEmpty ? nil : chatTools,
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

                        // Convert completion to Response
                        let response = completion.toResponse(
                            input: turnState.nextInput,
                            agent: agent,
                            modelSettings: agent.modelSettings
                        )

                        // Build span data for generation
                        let inputMessages: [[String: JSONValue]] = messages.map { msg in
                            var dict: [String: JSONValue] = [
                                "role": JSONValue(msg.role.rawValue)
                            ]

                            // only add content if it is not empty
                            if let content = msg.content {
                                switch content {
                                    case let .text(text):
                                        if !text.isEmpty {
                                            dict["content"] = JSONValue(text)
                                        }
                                    case let .parts(parts):
                                        // OpenAI's traces ingest accepts
                                        // only `text` and `image` content
                                        // discriminators — NOT the
                                        // `image_url` / `input_text` /
                                        // `output_text` shapes the chat
                                        // and Responses APIs use. Without
                                        // this collapse, image-bearing
                                        // generation spans get rejected
                                        // with "Invalid discriminator
                                        // value. Expected 'text' | 'image'"
                                        // and silently swallowed by
                                        // BackendSpanExporter — that's
                                        // why LM Studio image runs never
                                        // appeared on the dashboard.
                                        let structured: [[String: JSONValue]] = parts.compactMap { part in
                                            if let text = part.text {
                                                return ["type": JSONValue("text"), "text": JSONValue(text)]
                                            }
                                            if let url = part.imageURL?.url {
                                                return ["type": JSONValue("image"), "image_url": JSONValue(url)]
                                            }
                                            return nil
                                        }
                                        if !structured.isEmpty {
                                            dict["content"] = JSONValue(structured)
                                        }
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

                        let outputMessages: [[String: JSONValue]] = response.output.map(Self.outputItemToDict)

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

                        resultSpan.spanData = GenerationSpanData(
                            input: inputMessages,
                            output: outputMessages,
                            model: model,
                            modelConfig: modelConfig,
                            usage: usage
                        )

                        // Assistant message gets added to the session below
                        // via `OutputItem.toInputElement()` so the session
                        // remains the single source of truth for history.

                        return response
                    }
                }

                // Update the chain tracker from the latest response. No-op
                // when the response carries no usable id (mirrors Python's
                // resume-hydration semantics across providers).
                await tracker.update(from: response)

                // Append the assistant's outputs to the session so the next
                // turn — and any resumption of this session — picks them up.
                let responseElements = response.output.compactMap { $0.toInputElement() }
                if !responseElements.isEmpty {
                    try await session.addItems(responseElements)
                }

                var newInputs = [Response.Input.Element]()
                var functionCalls = [OutputItem.FunctionCall]()

                for outputItem in response.output {
                    switch outputItem {
                        case let .functionCall(functionCall):
                            if let handoff = agent.handoffs.first(where: { $0.toolName == functionCall.name }),
                               let targetAgent = handoff.targetAgent {
                                do {
                                    if handoff.inputType.self == Void.self {
                                        try await handoff.callPerform(input: ())
                                    } else {
                                        if let payload = functionCall.arguments.data(using: .utf8),
                                           let codableType = handoff.inputType as? Decodable.Type {
                                            let typedInput = try JSONDecoder().decode(codableType, from: payload)
                                            try await handoff.callPerform(input: typedInput)
                                        }
                                    }
                                } catch {
                                    let inputElement = Response.Input.Element.functionCallOutput(.init(
                                        callId: functionCall.callId,
                                        output: error.localizedDescription
                                    ))
                                    newInputs.append(inputElement)
                                    continue
                                }

                                try await withSpan { span in
                                    span.spanData = HandoffSpanData(fromAgent: agent.name, toAgent: targetAgent.name)

                                    // respond with standard transfer message that only mentions the new agent name
                                    let inputElement = Response.Input.Element.functionCallOutput(.init(
                                        callId: functionCall.callId,
                                        output: handoff.getTransferMessage()
                                    ))
                                    newInputs.append(inputElement)
                                }

                                // Store updates before returning. The
                                // chain pointer was already updated via
                                // `tracker.update(from: response)`; here we
                                // just stash the handoff payload as the
                                // next agent's input and persist it.
                                if !newInputs.isEmpty {
                                    turnState.nextInput = .array(newInputs)
                                    try await session.addItems(newInputs)
                                }

                                // Return the handoff agent directly
                                return AgentResult<A.OutputType>.handOff(targetAgent)
                            } else {
                                functionCalls.append(functionCall)
                            }
                        case let .reasoning(reasoningOutput):
                            roundReasoning = reasoningOutput.summary.map(\.text).joined(separator: "\n\n")
                        case let .message(messageOutput):
                            for output in messageOutput.content {
                                // get the last message text of the last output
                                if case let .outputText(outputText) = output {
                                    roundResult = outputText.text
                                }
                            }
                        case .mcpListTools:
                            // Decide how to handle this - for now, just continue
                            // This might involve logging, preparing a new input, or specific actions
                            logAgent("Received mcp_list_tools output, continuing.")
                            continue
                        case let .mcpApprovalRequest(approvalRequest):
                            logAgent(
                                "Received mcp_approval_request (id: \(approvalRequest.id)), automatically approving."
                            )
                            let approvalResponse = Response.Input.Element.mcpApprovalResponse(
                                Response.Input.MCPApprovalResponseInput(
                                    approve: true,
                                    approvalRequestId: approvalRequest.id
                                )
                            )
                            newInputs.append(approvalResponse)
                            // Continue to the next iteration to process newInputs
                            continue
                        case let .mcpCall(mcpCall):
                            logAgent("Received mcp_call output (id: \(mcpCall.id)), continuing.")
                            continue
                        case let .applyPatchCall(patchCall):
                            let result = executeApplyPatch(patchCall, agent: agent)
                            newInputs.append(.applyPatchCallOutput(result))
                        default:
                            continue
                    }
                }

                if !functionCalls.isEmpty {
                    let results = try await agent.executeToolCalls(functionCalls)
                    newInputs.append(contentsOf: results)
                }

                if !newInputs.isEmpty {
                    turnState.nextInput = .array(newInputs)
                    // Persist tool outputs / approvals so a resumed session
                    // sees them and a stateless provider replays them.
                    try await session.addItems(newInputs)
                } else {
                    if functionCalls.isEmpty {
                        if A.OutputType.self == String.self {
                            // swiftlint:disable:next force_cast - guarded above by `A.OutputType.self == String.self`.
                            return AgentResult.finalOutput(roundResult as! A.OutputType, roundReasoning)
                        } else if let data = roundResult.data(using: .utf8) {
                            if let decoded = decoder.decodeWithResultsUnwrap(data, as: A.OutputType.self) {
                                return AgentResult.finalOutput(decoded, roundReasoning)
                            }
                        }

                        // invalid response, just do the same response a second time
                        logAgent("Invalid response, repeating.\n\n\(roundResult)")
                    }
                }

            } catch {
                throw error
            }

            try Task.checkCancellation()

            // try another round

            // wait so that the next span has a slightly later start time
            try? await Task.sleep(nanoseconds: 200_000)
        }

        throw RunnerError.exceededMaxTurns
    }

    // Stateless helpers (`executeApplyPatch`, `makeGenerationSpanForResponse`,
    // `inputToMessageDicts`, `outputItemToDict`, `checkOutputGuardrails`)
    // live in `Runner+Helpers.swift` to keep this actor body focused on the
    // per-turn state machine.
}
