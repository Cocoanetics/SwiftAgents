//
//  Runner+Helpers.swift
//  SwiftAgents
//
//  Stateless helpers split out of Runner.swift to keep the main actor body
//  focused on the per-turn state machine: span-shape synthesis, the
//  `Response.Input` ↔ message-dict translation used by GenerationSpanData,
//  the OutputItem dict serializer used by trace exporters, the
//  apply_patch dispatch, and the output-guardrail fan-out.

import Foundation
import Providers
import Tracing
import SwiftMCP

/// Surfaced when the caller combines `session` with any of
/// `conversationId` / `previousResponseId` / `autoPreviousResponseId`.
/// Mirrors `openai-agents-python`'s `UserError`.
public struct SessionConversationConfigurationError: Error, CustomStringConvertible {
    public let description: String

    init() {
        self.description = """
        Session persistence cannot be combined with conversationId, \
        previousResponseId, or autoPreviousResponseId.
        """
    }
}

extension Runner {
    /// Discovers tools from every MCP server proxy on the agent and
    /// returns them as `[Tool]`. Wraps each server probe in its own
    /// `MCPListToolsSpanData` span so trace consumers can see which
    /// server contributed which names.
    static func collectMCPTools(for agent: some Agent) async throws -> [Tool] {
        var collected: [Tool] = []
        for proxy in agent.mcpServers {
            collected += try await withSpan { mcpListSpan in
                let serverName = await proxy.serverName
                let mcpTools = try await proxy.listTools()
                let myTools = mcpTools.map { mcpTool in
                    // Pass the MCP tool's input schema through unmodified —
                    // required, description, additionalProperties all survive.
                    Tool.function(FunctionTool(
                        name: mcpTool.name,
                        description: mcpTool.description,
                        parameters: mcpTool.inputSchema,
                        strict: false
                    ))
                }
                let names = mcpTools.map(\.name)
                mcpListSpan.spanData = MCPListToolsSpanData(server: serverName, result: names)
                return myTools
            }
        }
        return collected
    }

    /// Realizes an `.image` request as the OpenAI Responses built-in
    /// `image_generation` tool — the provider-specific mechanism for image
    /// output on OpenAI. This is where image realization lives, not in the
    /// agent: agents only declare the neutral `requestedMedia` intent.
    ///
    /// No-ops (returns `tools` unchanged) when the provider isn't OpenAI's
    /// Responses API (Gemini shapes image output through the request via
    /// `responseModalities` + `imageConfig`; other providers don't support the
    /// tool), no image was requested, or the caller already supplied an
    /// explicit `image_generation` tool — which wins, carrying its own options.
    static func realizingImageTool(_ tools: [Tool], for media: [RequestedMedia], api: API) -> [Tool] {
        guard api.statePolicy.responseIdsAreOpenAIRoutable, media.requestsImage else { return tools }
        let alreadyPresent = tools.contains { tool in
            if case .imageGeneration = tool { true } else { false }
        }
        guard !alreadyPresent else { return tools }
        let options = media.firstImageOptions ?? ImageOptions()
        return [.imageGeneration(options.imageGenerationTool)] + tools
    }

    /// Decides whether this turn should go through the provider's
    /// stateful path (Responses API) or fall back to chat completions.
    /// Bypass the stateful path for structured-output turns when the
    /// policy says the endpoint silently ignores the schema (LM Studio's
    /// `/v1/responses` is the current case) — chat completions wires
    /// `response_format` correctly so the model actually constrains.
    static func shouldUseStatefulPath(
        policy: ConversationStatePolicy,
        outputType: TextFormat
    ) -> Bool {
        guard policy.supportsServerSideHistory else { return false }
        let needsStructuredOutput: Bool = switch outputType {
            case .text: false
            case .json, .jsonSchema: true
        }
        if needsStructuredOutput, !policy.supportsStructuredOutput { return false }
        return true
    }

    /// Dispatch one stateful turn, choosing incremental vs. full input and
    /// recovering from a lost chain base.
    ///
    /// When the server already holds prior context (a `previousResponseId` or
    /// `conversationId` is set) only the new delta (`nextInput`) is sent;
    /// otherwise the full session history is replayed so the server can
    /// reconstruct the conversation.
    ///
    /// If the turn fails with `previous_response_not_found` — common under
    /// `store=false` / Zero Data Retention, or after a WebSocket transport
    /// evicts its connection-local cache — the chain base is gone server-side.
    /// Reset the chain pointer and resend the full reconstructed context (the
    /// `Session` is the source of truth) as a brand-new chain.
    static func dispatchStatefulTurn(
        stateful: any ServerHistoryAPI,
        nextInput: Response.Input,
        model: String,
        instructions: String?,
        previousResponseId: String?,
        conversationId: String?,
        textFormat: TextFormat?,
        tools: [Tool]?,
        modelSettings: ModelSettings,
        tracker: ConversationStateTracker,
        session: Providers.Session
    ) async throws -> Response {
        let primaryInput: Response.Input
        if previousResponseId != nil || conversationId != nil {
            primaryInput = nextInput
        } else {
            let sessionItems = try await session.getItems()
            primaryInput = sessionItems.isEmpty ? nextInput : .array(sessionItems)
        }

        do {
            return try await stateful.dispatchCreateResponse(
                input: primaryInput,
                model: model,
                instructions: instructions,
                previousResponseId: previousResponseId,
                conversationId: conversationId,
                textFormat: textFormat,
                tools: tools,
                modelSettings: modelSettings
            )
        } catch let APIError.previousResponseNotFound(param) {
            // Full-context recovery is only sound when we can actually
            // reconstruct the conversation: either the `Session` holds the whole
            // history (the run did not resume from an external
            // `previousResponseId`), or a `conversationId` is still set so the
            // server can rebuild it on the retry. Otherwise the `Session`
            // contains only this run's latest input, and resending it with the
            // chain nulled would silently drop all prior context — surface the
            // failure instead.
            let resumedExternally = tracker.startedFromExternalResponseId
            guard !resumedExternally || conversationId != nil else {
                throw APIError.previousResponseNotFound(param: param)
            }

            await tracker.resetChain()
            let fullItems = try await session.getItems()
            let fullInput: Response.Input = fullItems.isEmpty ? nextInput : .array(fullItems)
            return try await stateful.dispatchCreateResponse(
                input: fullInput,
                model: model,
                instructions: instructions,
                previousResponseId: nil,
                conversationId: conversationId,
                textFormat: textFormat,
                tools: tools,
                modelSettings: modelSettings
            )
        }
    }

    /// Flattens a (possibly multimodal) `Response.Input` to a plain string
    /// for guardrails that evaluate text only. Concatenates the
    /// `inputText` / `outputText` content of any message elements;
    /// non-text parts (images, file ids) are dropped. Mirrors what
    /// Python's guardrails receive — they evaluate against a string and
    /// ignore image parts.
    static func flattenInputText(_ input: Response.Input) -> String {
        switch input {
            case let .text(text):
                return text
            case let .array(elements):
                return elements.compactMap { element -> String? in
                    guard case let .message(msg) = element else { return nil }
                    let texts = msg.content.compactMap { part -> String? in
                        switch part {
                            case let .inputText(text), let .outputText(text):
                                return text
                            default:
                                return nil
                        }
                    }
                    return texts.isEmpty ? nil : texts.joined(separator: "\n")
                }.joined(separator: "\n")
        }
    }

    /// Reject configurations that would double-count history. A `Session`
    /// is the canonical conversation log the runner reads/writes; the three
    /// server-pointer kwargs delegate that responsibility to the provider.
    /// Combining them would either re-send items the server already has or
    /// shadow the session's view of "what was said." Mirrors Python's
    /// `validate_session_conversation_settings`.
    static func validateSessionConversationSettings(
        session: Providers.Session?,
        conversationId: String?,
        previousResponseId: String?,
        autoPreviousResponseId: Bool
    ) throws {
        guard session != nil else { return }
        if conversationId == nil, previousResponseId == nil, !autoPreviousResponseId {
            return
        }
        throw SessionConversationConfigurationError()
    }

    /// Wraps `agent.applyPatch(path:diff:type:)` and constructs the result.
    static func executeApplyPatch(_ call: ApplyPatchCallOutput, agent: some Agent) -> ApplyPatchCallOutputResult {
        guard let patcher = agent as? AppliesPatches else {
            return ApplyPatchCallOutputResult(
                callId: call.resolvedCallId,
                output: "Error: Agent does not support apply_patch",
                status: .failed
            )
        }
        do {
            try patcher.applyPatch(path: call.operation.path, diff: call.operation.diff, type: call.operation.type)
            let verb = switch call.operation.type {
                case .createFile: "Created"
                case .updateFile: "Updated"
                case .deleteFile: "Deleted"
            }
            return ApplyPatchCallOutputResult(callId: call.resolvedCallId, output: "\(verb) \(call.operation.path)")
        } catch {
            return ApplyPatchCallOutputResult(
                callId: call.resolvedCallId,
                output: "Error: \(error.localizedDescription)",
                status: .failed
            )
        }
    }

    /// Variant that reads the full session as the span input, falling
    /// back to a provided `Response.Input` when the session is empty
    /// (first-turn case, or no session). Keeps the call site in
    /// `Runner.run` compact.
    static func makeGenerationSpanForResponse(
        session: Providers.Session,
        fallback: Response.Input,
        instructions: String?,
        response: Response,
        model: String,
        modelSettings: ModelSettings,
        baseURL: String
    ) async throws -> GenerationSpanData {
        let sessionItems = try await session.getItems()
        let input: Response.Input = sessionItems.isEmpty ? fallback : .array(sessionItems)
        return makeGenerationSpanForResponse(
            input: input,
            instructions: instructions,
            response: response,
            model: model,
            modelSettings: modelSettings,
            baseURL: baseURL
        )
    }

    /// Synthesise a `GenerationSpanData` describing a stateful turn whose
    /// `response_id` shouldn't be exported to OpenAI tracing. Mirrors the
    /// dict shape the chat-completions branch produces so trace consumers
    /// see a uniform `generation` span regardless of which endpoint was
    /// actually called.
    static func makeGenerationSpanForResponse(
        input: Response.Input,
        instructions: String?,
        response: Response,
        model: String,
        modelSettings: ModelSettings,
        baseURL: String
    ) -> GenerationSpanData {
        var inputMessages: [[String: JSONValue]] = []
        if let instructions, !instructions.isEmpty {
            inputMessages.append([
                "role": JSONValue("system"),
                "content": JSONValue(instructions)
            ])
        }
        inputMessages.append(contentsOf: inputToMessageDicts(input))

        let outputMessages = response.output.map(outputItemToDict)

        let modelConfig: [String: JSONValue] = [
            "temperature": JSONValue(modelSettings.temperature),
            "top_p": JSONValue(modelSettings.topP),
            "frequency_penalty": JSONValue(modelSettings.frequencyPenalty),
            "presence_penalty": JSONValue(modelSettings.presencePenalty),
            "tool_choice": JSONValue(modelSettings.toolChoice),
            "parallel_tool_calls": JSONValue(modelSettings.parallelToolCalls),
            "truncation": JSONValue(modelSettings.truncation),
            "max_tokens": JSONValue(modelSettings.maxCompletionTokens),
            "reasoning": JSONValue(modelSettings.reasoning),
            "metadata": JSONValue(modelSettings.metadata),
            "store": JSONValue(modelSettings.store),
            "include_usage": JSONValue(modelSettings.includeUsage),
            "extra_query": JSONValue(modelSettings.extraQuery),
            "extra_body": JSONValue(modelSettings.extraBody),
            "extra_headers": JSONValue(modelSettings.extraHeaders),
            "base_url": JSONValue(modelSettings.baseURL ?? baseURL)
        ]

        let usage: [String: JSONValue] = [
            "input_tokens": JSONValue(response.usage?.inputTokens ?? 0),
            "output_tokens": JSONValue(response.usage?.outputTokens ?? 0)
        ]

        return GenerationSpanData(
            input: inputMessages,
            output: outputMessages,
            model: model,
            modelConfig: modelConfig,
            usage: usage
        )
    }

    /// Best-effort conversion of `Response.Input` into the
    /// `[[String: JSONValue]]` message-dict shape used by `GenerationSpanData`.
    /// Element kinds the runner actually sends (user/system text + images,
    /// tool call outputs, function calls) are mapped; other shapes are
    /// dropped from the span rather than misrepresented.
    ///
    /// Content parts use OpenAI's trace-ingest taxonomy (`text` / `image`,
    /// NOT `input_text` / `image_url`) so spans round-trip through
    /// `openAI.ingestTraces` without rejection.
    static func inputToMessageDicts(_ input: Response.Input) -> [[String: JSONValue]] {
        switch input {
            case let .text(text):
                return [[
                    "role": JSONValue("user"),
                    "content": JSONValue(text)
                ]]
            case let .array(elements):
                return elements.compactMap { element -> [String: JSONValue]? in
                    switch element {
                        case let .message(msg):
                            let parts: [[String: JSONValue]] = msg.content.compactMap { piece in
                                switch piece {
                                    case let .inputText(text), let .outputText(text):
                                        return ["type": JSONValue("text"), "text": JSONValue(text)]
                                    case let .inputImage(url):
                                        guard let url else { return nil }
                                        return ["type": JSONValue("image"),
                                                "image_url": JSONValue(url.absoluteString)]
                                    case let .inputImageFileID(fileID):
                                        return ["type": JSONValue("image"),
                                                "file_id": JSONValue(fileID)]
                                }
                            }
                            guard !parts.isEmpty else { return nil }
                            // Collapse a single text part to a bare string
                            // (matches what the chat-completions branch
                            // emits for the same shape).
                            if parts.count == 1,
                               case let .string(type) = parts[0]["type"] ?? .null,
                               type == "text",
                               case let .string(text) = parts[0]["text"] ?? .null {
                                return [
                                    "role": JSONValue(msg.role.rawValue),
                                    "content": JSONValue(text)
                                ]
                            }
                            return [
                                "role": JSONValue(msg.role.rawValue),
                                "content": JSONValue(parts)
                            ]
                        case let .functionCallOutput(output):
                            return [
                                "role": JSONValue("tool"),
                                "tool_call_id": JSONValue(output.callId),
                                "content": JSONValue(output.output)
                            ]
                        case let .functionCall(call):
                            return [
                                "role": JSONValue("assistant"),
                                "tool_calls": JSONValue([[
                                    "id": JSONValue(call.callId),
                                    "type": JSONValue("function"),
                                    "function": JSONValue([
                                        "name": JSONValue(call.name),
                                        "arguments": JSONValue(call.arguments)
                                    ])
                                ]])
                            ]
                        default:
                            return nil
                    }
                }
        }
    }

    /// Builds the `GenerationSpanData` input-message dicts for a
    /// chat-completion turn from the wire `[ChatMessage]`. Content parts are
    /// collapsed to OpenAI's trace-ingest taxonomy (`text` / `image`, NOT
    /// `image_url` / `input_text`): without this collapse, image-bearing
    /// generation spans are rejected with "Invalid discriminator value.
    /// Expected 'text' | 'image'" and silently dropped by the exporter.
    static func chatInputMessageDicts(from messages: [ChatMessage]) -> [[String: JSONValue]] {
        messages.map { msg in
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
    }

    /// Helper to serialize OutputItem to a dictionary for tracing
    static func outputItemToDict(_ item: OutputItem) -> [String: JSONValue] {
        switch item {
            case let .message(message):
                let content = message.content.compactMap { content in
                    if case let .outputText(textContent) = content { return textContent.text }
                    return nil
                }.joined(separator: "\n")
                return [
                    "type": JSONValue("message"),
                    "role": JSONValue(message.role.rawValue),
                    "content": JSONValue(content)
                ]
            case let .functionCall(call):
                // Try to decode arguments as JSON, fallback to string
                let args = if let data = call.arguments.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) {
                    JSONValue(jsonObject: obj)
                } else {
                    JSONValue(call.arguments)
                }
                return [
                    "type": JSONValue("tool_call"),
                    "tool_call_id": JSONValue(call.callId),
                    "tool_name": JSONValue(call.name),
                    "arguments": args
                ]
            case let .fileSearch(file):
                return [
                    "type": JSONValue("file_search"),
                    "id": JSONValue(file.id),
                    "queries": JSONValue(file.queries),
                    "results": JSONValue(file.results ?? [])
                ]
            case let .webSearch(web):
                return [
                    "type": JSONValue("web_search"),
                    "id": JSONValue(web.id)
                ]
            case let .computer(comp):
                return [
                    "type": JSONValue("computer"),
                    "id": JSONValue(comp.id),
                    "action": JSONValue(String(describing: comp.action))
                ]
            case let .reasoning(reasoning):
                let text = reasoning.summary.map(\.text).joined(separator: "\n")
                return [
                    "type": JSONValue("reasoning"),
                    "content": JSONValue(text)
                ]
            case let .mcpListTools(mcpList):
                return [
                    "type": JSONValue("mcp_list_tools"),
                    "id": JSONValue(mcpList.id),
                    "server_label": JSONValue(mcpList.serverLabel),
                    "tools": JSONValue(mcpList.tools.map { tool in
                        [
                            "name": JSONValue(tool.name),
                            "description": JSONValue(tool.description),
                            "input_schema": JSONValue(tool.inputSchema),
                            "annotations": JSONValue(tool.annotations)
                        ]
                    })
                ]
            case let .mcpApprovalRequest(approval):
                return [
                    "type": JSONValue("mcp_approval_request"),
                    "id": JSONValue(approval.id),
                    "name": JSONValue(approval.name),
                    "server_label": JSONValue(approval.serverLabel),
                    "arguments": JSONValue(approval.arguments)
                ]
            case let .mcpCall(mcpCall):
                return [
                    "type": JSONValue("mcp_call"),
                    "id": JSONValue(mcpCall.id),
                    "approval_request_id": JSONValue(mcpCall.approvalRequestId),
                    "arguments": JSONValue(mcpCall.arguments),
                    "error": JSONValue(mcpCall.error),
                    "name": JSONValue(mcpCall.name),
                    "output": JSONValue(mcpCall.output),
                    "server_label": JSONValue(mcpCall.serverLabel)
                ]
            case let .applyPatchCall(patchCall):
                return [
                    "type": JSONValue("apply_patch_call"),
                    "id": JSONValue(patchCall.id),
                    "operation_type": JSONValue(patchCall.operation.type.rawValue),
                    "path": JSONValue(patchCall.operation.path)
                ]
            case let .imageGenerationCall(call):
                // Record the metadata but not the (potentially large) base64
                // image bytes.
                return [
                    "type": JSONValue("image_generation_call"),
                    "id": JSONValue(call.id),
                    "status": JSONValue(call.status ?? ""),
                    "revised_prompt": JSONValue(call.revisedPrompt ?? ""),
                    "size": JSONValue(call.size ?? ""),
                    "byte_count": JSONValue(call.result?.count ?? 0)
                ]
        }
    }

    /// Resolves a completed turn into the agent's typed final output.
    ///
    /// Three special cases sit ahead of the JSON path, each keyed on the
    /// concrete `OutputType` so the `as!` casts are provably safe:
    ///   - `String`: the raw assistant text.
    ///   - `GeneratedFile`: the image bytes captured from an
    ///     `image_generation_call` this turn (`nil` if none arrived yet).
    ///   - everything else `Decodable`: decoded from the assistant text.
    ///
    /// Returns `nil` when the response can't be turned into the output type
    /// (no image yet, or undecodable JSON) so the caller repeats the turn.
    static func terminalOutput<A: Agent>(
        for _: A.Type,
        text: String,
        file: GeneratedFile?,
        reasoning: String?,
        decoder: JSONDecoder
    ) -> AgentResult<A.OutputType>? {
        if A.OutputType.self == String.self {
            // swiftlint:disable:next force_cast - guarded by the type check above.
            return .finalOutput(text as! A.OutputType, reasoning)
        }
        if A.OutputType.self == GeneratedFile.self {
            guard let file else { return nil }
            // swiftlint:disable:next force_cast - guarded by the type check above.
            return .finalOutput(file as! A.OutputType, reasoning)
        }
        if let data = text.data(using: .utf8),
           let decoded = decoder.decodeWithResultsUnwrap(data, as: A.OutputType.self) {
            return .finalOutput(decoded, reasoning)
        }
        return nil
    }

    static func checkOutputGuardrails<A: Agent>(
        _ guardrails: [any OutputGuardrail],
        output: A.OutputType,
        agent: A
    ) async throws {
        if guardrails.isEmpty { return }

        try await withThrowingTaskGroup(of: OutputGuardrailResult?.self) { group in
            for guardrail in guardrails {
                group.addTask {
                    try await withSpan { span in
                        let result = try await guardrail.evaluate(output, agent: agent)

                        let outputResult = OutputGuardrailResult(
                            guardrail: guardrail,
                            agentOutput: (output as? any Encodable)
                                .map(JSONValue.init) ?? .string(String(describing: output)),
                            agent: agent,
                            output: result
                        )
                        span.spanData = GuardrailSpanData(
                            name: guardrail.name,
                            triggered: result.tripwireTriggered
                        )
                        return outputResult
                    }
                }
            }
            // As soon as one returns tripwireTriggered, cancel all and throw
            while let result = try await group.next() {
                if let guardrailResult = result, guardrailResult.output.tripwireTriggered {
                    group.cancelAll()
                    throw OutputGuardrailTripwireTriggered(
                        guardrailName: guardrailResult.guardrail.name,
                        result: guardrailResult.output
                    )
                }
            }
        }
    }
}
