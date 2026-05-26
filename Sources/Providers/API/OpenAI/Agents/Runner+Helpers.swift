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
                let names = mcpTools.map(\.name)
                mcpListSpan.spanData = MCPListToolsSpanData(server: serverName, result: names)
                return myTools
            }
        }
        return collected
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
        session: Session?,
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
        }
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
