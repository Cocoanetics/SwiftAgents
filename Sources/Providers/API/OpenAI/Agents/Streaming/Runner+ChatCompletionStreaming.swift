import Foundation
import SwiftMCP

extension Runner {
    // MARK: - Chat Completion Streamed Turn Execution

    /// Streams an agent turn against providers that only expose the
    /// chat-completion shape (Anthropic, OpenAI-compatible local servers,
    /// etc.). Walks `Chunk` deltas and emits the same `AgentStreamEvent`
    /// surface as the Responses path so consumers don't need to branch on
    /// provider.
    ///
    /// `chatHistory` is threaded across handoffs so the receiving agent
    /// continues from the prior conversation (including the handoff tool
    /// result) instead of restarting from the user input. The caller swaps
    /// the system prompt to the new agent's instructions before re-invoking.
    ///
    /// If `api.createChatCompletionStream` reports the provider doesn't
    /// support streaming yet, we degrade to one synthetic event at the end
    /// — matching the prior behaviour for those providers.
    static func executeChatCompletionStreamedTurns<A: Agent>(
        agent: A,
        tools: [Tool],
        maxTurns: Int,
        model: String,
        api: API,
        input: String,
        chatHistory: inout [ChatMessage],
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws -> AgentResult<A.OutputType> {
        if chatHistory.isEmpty {
            chatHistory = [
                ChatMessage(role: .system, content: .text(agent.instructions)),
                ChatMessage(role: .user, content: .text(input))
            ]
        }
        var turns = 0

        while turns < maxTurns {
            turns += 1

            try Task.checkCancellation()

            var roundResult = ""
            var assembledMessage: ChatMessage?

            try await withSpan { resultSpan in
                // Omit `tools` entirely when empty — LM Studio reads
                // `tools: []` as a request to enable lazy-grammar tool
                // calling, which conflicts with `response_format`
                // structured-output constraints.
                let chatTools = tools.toolDescriptions
                let toolsArg = chatTools.isEmpty ? nil : chatTools

                let stream: AsyncThrowingStream<Chunk, Error>
                do {
                    stream = try await api.createChatCompletionStream(
                        model: model,
                        messages: chatHistory,
                        tools: toolsArg,
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
                    // Provider hasn't wired chat-completion streaming yet
                    // (e.g. Google). Degrade to one non-streaming call.
                    let completion = try await api.createChatCompletion(
                        model: model,
                        messages: chatHistory,
                        tools: toolsArg,
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
                // Chat-completion streams only send tool_call `id` on the
                // first delta; later argument chunks carry just `index`.
                // Cache id by index so itemId stays stable per tool call.
                var toolCallIDByIndex: [Int: String] = [:]

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
                            let index = toolDelta.index ?? 0
                            if let id = toolDelta.id, !id.isEmpty {
                                toolCallIDByIndex[index] = id
                            }
                            let resolvedID = toolCallIDByIndex[index] ?? chunk.id

                            if let json = toolDelta.function?.arguments, !json.isEmpty {
                                let info = ResponsesStreamEvent.FunctionCallArgumentsDeltaInfo(
                                    itemId: resolvedID,
                                    outputIndex: index,
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

            // Lift any tool calls into the Responses-shaped FunctionCall
            // the rest of the runner machinery already understands.
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

                    // Close the handoff tool call with its result so the
                    // receiving agent sees a complete tool-use turn — a
                    // dangling tool_call would cause providers like
                    // Anthropic to reject the next request.
                    chatHistory.append(ChatMessage(
                        role: .tool,
                        content: .text(handoff.getTransferMessage()),
                        toolCallID: functionCall.callId
                    ))

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

    /// Builds `GenerationSpanData` from a fully-assembled chat completion
    /// and stores it on the current response span. Mirrors the dictionary
    /// shape used by `Runner.executeAgentTurns`'s non-streaming chat path
    /// so traces look the same regardless of provider or stream mode.
    static func recordGenerationSpan<A: Agent>(
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
