//
//  Anthropic+Converters.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.05.26.
//
//  Bridges SwiftAgents' OpenAI-shaped types (`ChatMessage`, `Response.Input`,
//  `Tool`, `ToolDescription`) and Anthropic's native Messages API types.

import Foundation
import SwiftMCP

extension Anthropic {
    // MARK: - ChatMessage[] → Anthropic

    /// Splits a chat-completion-style message array into:
    /// - the system prompt (concatenated text from all system/developer messages), and
    /// - the user/assistant/tool turns expressed as `AnthropicMessage`s.
    static func convertChatMessages(
        _ messages: [ChatMessage]
    ) -> (system: AnthropicSystem?, messages: [AnthropicMessage]) {
        var systemPieces: [String] = []
        var converted: [AnthropicMessage] = []

        for message in messages {
            switch message.role {
                case .system, .developer:
                    if let text = message.textContent, !text.isEmpty {
                        systemPieces.append(text)
                    } else if let parts = message.contentParts {
                        let text = ChatMessage.ContentPart.textParts(from: parts).joined(separator: "\n")
                        if !text.isEmpty { systemPieces.append(text) }
                    }

                case .user:
                    let blocks = anthropicBlocks(from: message)
                    if !blocks.isEmpty {
                        converted.append(AnthropicMessage(role: .user, content: .blocks(blocks)))
                    }

                case .assistant:
                    var blocks: [AnthropicContentBlock] = anthropicBlocks(from: message)
                    if let toolCalls = message.toolCalls {
                        for call in toolCalls {
                            guard let function = call.function else { continue }
                            let input = (try? function.argumentsDictionary()) ?? [:]
                            blocks.append(.toolUse(.init(
                                id: call.id,
                                name: function.name,
                                input: .object(input)
                            )))
                        }
                    }
                    if !blocks.isEmpty {
                        converted.append(AnthropicMessage(role: .assistant, content: .blocks(blocks)))
                    }

                case .tool, .function:
                    guard let callId = message.toolCallID else { continue }
                    let result = message.textContent ?? ""
                    let block = AnthropicContentBlock.toolResult(.init(
                        toolUseId: callId,
                        content: .text(result)
                    ))
                    // Tool results live inside a user-role message.
                    if case let .blocks(existing)? = converted.last?.content,
                        converted.last?.role == .user {
                        converted[converted.count - 1] = AnthropicMessage(
                            role: .user,
                            content: .blocks(existing + [block])
                        )
                    } else {
                        converted.append(AnthropicMessage(role: .user, content: .blocks([block])))
                    }
            }
        }

        let system: AnthropicSystem? = systemPieces.isEmpty
            ? nil
            : .text(systemPieces.joined(separator: "\n\n"))
        return (system, converted)
    }

    /// Builds Anthropic content blocks from a `ChatMessage`'s content (text or
    /// multi-part), preserving images via `image_url` data-URL decoding.
    private static func anthropicBlocks(from message: ChatMessage) -> [AnthropicContentBlock] {
        if let parts = message.contentParts {
            return parts.compactMap { part -> AnthropicContentBlock? in
                switch part.type {
                    case .text:
                        guard let text = part.text, !text.isEmpty else { return nil }
                        return .text(.init(text: text))
                    case .imageURL:
                        return imageBlock(from: part)
                    case .inputAudio, .file:
                        // Audio + arbitrary files aren't supported by the Messages API.
                        return nil
                }
            }
        }
        if let text = message.textContent, !text.isEmpty {
            return [.text(.init(text: text))]
        }
        return []
    }

    /// Converts an OpenAI-shaped image content part into an Anthropic image
    /// block. Data URLs are split into `(media_type, base64)`; http(s) URLs
    /// pass through as `source: { type: "url", url: ... }`.
    private static func imageBlock(from part: ChatMessage.ContentPart) -> AnthropicContentBlock? {
        if let decoded = part.decodedImageData() {
            return .image(.init(source: .base64(
                mediaType: decoded.mimeType,
                data: decoded.data.base64EncodedString()
            )))
        }
        guard let url = part.imageURL?.url else { return nil }
        return .image(.init(source: .url(url)))
    }

    // MARK: - Response.Input → Anthropic

    /// Same split as `convertChatMessages` but starting from the Responses API
    /// input shape used by the Agents SDK.
    static func convertResponseInput(
        _ input: Response.Input,
        instructions: String?
    ) -> (system: AnthropicSystem?, messages: [AnthropicMessage]) {
        var messages: [AnthropicMessage] = []
        var systemPieces: [String] = []
        if let instructions, !instructions.isEmpty {
            systemPieces.append(instructions)
        }

        switch input {
            case let .text(text):
                messages.append(AnthropicMessage(role: .user, content: .text(text)))

            case let .array(elements):
                for element in elements {
                    switch element {
                        case let .message(message):
                            // Responses API `Role` includes system/developer too — fold them into the system prompt.
                            switch message.role {
                                case .system, .developer:
                                    let texts = message.content.compactMap { element -> String? in
                                        if case let .inputText(text) = element {
                                            return text
                                        }
                                        return nil
                                    }
                                    if !texts.isEmpty { systemPieces.append(contentsOf: texts) }
                                case .user, .assistant:
                                    let role: AnthropicMessage.Role
                                        = message.role == .assistant ? .assistant : .user
                                    let blocks = message.content.compactMap { element -> AnthropicContentBlock? in
                                        switch element {
                                            case let .inputText(text):
                                                return .text(.init(text: text))
                                            case let .inputImage(url):
                                                guard let url else { return nil }
                                                let raw = url.absoluteString
                                                if let part = ChatMessage.ContentPart(imageURL: raw)
                                                    .decodedImageData() {
                                                    return .image(.init(source: .base64(
                                                        mediaType: part.mimeType,
                                                        data: part.data.base64EncodedString()
                                                    )))
                                                }
                                                return .image(.init(source: .url(raw)))
                                            case .inputImageFileID:
                                                // OpenAI file IDs don't translate.
                                                return nil
                                        }
                                    }
                                    if !blocks.isEmpty {
                                        messages.append(AnthropicMessage(role: role, content: .blocks(blocks)))
                                    }
                                default:
                                    continue
                            }

                        case let .functionCall(call):
                            // Model previously chose to call a tool — re-emit as an assistant tool_use.
                            let input: JSONValue = (try? .object(call.argumentsDictionary())) ?? .object([:])
                            let block = AnthropicContentBlock.toolUse(.init(
                                id: call.callId,
                                name: call.name,
                                input: input
                            ))
                            messages.append(AnthropicMessage(role: .assistant, content: .blocks([block])))

                        case let .functionCallOutput(output):
                            let block = AnthropicContentBlock.toolResult(.init(
                                toolUseId: output.callId,
                                content: .text(output.output)
                            ))
                            if case let .blocks(existing)? = messages.last?.content,
                                messages.last?.role == .user {
                                messages[messages.count - 1] = AnthropicMessage(
                                    role: .user,
                                    content: .blocks(existing + [block])
                                )
                            } else {
                                messages.append(AnthropicMessage(role: .user, content: .blocks([block])))
                            }

                        default:
                            // reasoning / file_search_call / web_search_call etc. don't have
                            // a direct Anthropic equivalent for input; drop them.
                            continue
                    }
                }
        }

        let system: AnthropicSystem? = systemPieces.isEmpty
            ? nil
            : .text(systemPieces.joined(separator: "\n\n"))
        return (system, messages)
    }

    // MARK: - Tool Conversions

    /// `[Tool]` (Responses API enum) → `[AnthropicTool]` keeping only function tools.
    static func convertTools(_ tools: [Tool]?) -> [AnthropicTool]? {
        guard let tools, !tools.isEmpty else { return nil }
        let mapped = tools.compactMap { tool -> AnthropicTool? in
            guard case let .function(functionTool) = tool else { return nil }
            return AnthropicTool(
                name: functionTool.name,
                description: functionTool.description,
                inputSchema: functionTool.parameters
            )
        }
        return mapped.isEmpty ? nil : mapped
    }

    /// `[ToolDescription]` (Chat Completions style) → `[AnthropicTool]`.
    static func convertToolDescriptions(_ tools: [ToolDescription]?) -> [AnthropicTool]? {
        guard let tools, !tools.isEmpty else { return nil }
        let mapped = tools.compactMap { tool -> AnthropicTool? in
            guard let function = tool.function else { return nil }
            return AnthropicTool(
                name: function.name,
                description: function.description,
                inputSchema: function.parameters
            )
        }
        return mapped.isEmpty ? nil : mapped
    }

    /// Maps the Responses API `ToolChoice` enum onto Anthropic's tool_choice.
    static func convertToolChoice(_ choice: ToolChoice?) -> AnthropicToolChoice? {
        guard let choice else { return nil }
        switch choice {
            case .auto:
                return .auto(disableParallel: nil)
            case .required:
                return .any(disableParallel: nil)
            case .none:
                return AnthropicToolChoice.none
            case let .tool(description):
                if let name = description.function?.name {
                    return .tool(name: name, disableParallel: nil)
                }
                return .auto(disableParallel: nil)
        }
    }

    // MARK: - Response/ChatCompletion Mappers

    /// Maps Anthropic's `stop_reason` onto the OpenAI-shaped `FinishReason`
    /// used in `ChatCompletionResponse`. Unknown reasons fall back to `.stop`.
    static func chatFinishReason(from reason: AnthropicStopReason?) -> FinishReason? {
        switch reason {
            case .endTurn, .stopSequence, .pauseTurn:
                return .stop
            case .maxTokens:
                return .limit
            case .toolUse:
                return .toolCalls
            case .refusal:
                return .contentFilter
            case nil:
                return nil
        }
    }

    /// Wraps Anthropic's input/output token counts into the shared `Usage` shape.
    static func usage(from anthropic: AnthropicUsage?) -> Usage? {
        guard let anthropic else { return nil }
        let prompt = anthropic.inputTokens ?? 0
        let completion = anthropic.outputTokens ?? 0
        return Usage(promptTokens: prompt, completionTokens: completion, totalTokens: prompt + completion)
    }

    /// Wraps Anthropic's token counts into the Responses API `ResponsesUsage` shape.
    static func responsesUsage(from anthropic: AnthropicUsage?) -> ResponsesUsage? {
        guard let anthropic else { return nil }
        let prompt = anthropic.inputTokens ?? 0
        let completion = anthropic.outputTokens ?? 0
        return ResponsesUsage(
            inputTokens: prompt,
            inputTokensDetails: .init(cachedTokens: anthropic.cacheReadInputTokens ?? 0),
            outputTokens: completion,
            outputTokensDetails: .init(reasoningTokens: 0),
            totalTokens: prompt + completion
        )
    }

    /// Result of folding Anthropic content blocks into the OpenAI-shaped
    /// `ChatMessage` surface: the assistant message itself, plus any tool
    /// calls or reasoning text that came alongside it.
    struct ChatMessageFold {
        let message: ChatMessage
        let toolCalls: [ToolCall]
        let reasoning: String?
    }

    /// Folds Anthropic's `[ContentBlock]` into a `ChatMessage` (combined text
    /// segments) plus an array of `ToolCall`s — the shape consumed by callers
    /// of `createChatCompletion`.
    static func chatMessage(
        from blocks: [AnthropicContentBlock]
    ) -> ChatMessageFold {
        var textSegments: [String] = []
        var toolCalls: [ToolCall] = []
        var reasoningSegments: [String] = []

        for block in blocks {
            switch block {
                case let .text(text):
                    textSegments.append(text.text)
                case let .toolUse(toolUse):
                    let arguments = anthropicInputToJSONString(toolUse.input)
                    let function = FunctionCall(name: toolUse.name, arguments: arguments)
                    toolCalls.append(ToolCall(id: toolUse.id, type: "function", function: function))
                case let .thinking(thinking):
                    reasoningSegments.append(thinking.thinking)
                case .image, .toolResult:
                    // Anthropic returns these only in input — never assistant output.
                    continue
            }
        }

        let combined = textSegments.joined(separator: "\n")
        let content: ChatMessage.Content? = combined.isEmpty ? nil : .text(combined)
        var message = ChatMessage(role: .assistant, content: content)
        if !toolCalls.isEmpty { message.toolCalls = toolCalls }
        let reasoning = reasoningSegments.isEmpty ? nil : reasoningSegments.joined(separator: "\n")
        if let reasoning { message.reasoningContent = reasoning }
        return ChatMessageFold(message: message, toolCalls: toolCalls, reasoning: reasoning)
    }

    /// Folds Anthropic's `[ContentBlock]` into Responses API `OutputItem`s:
    /// text becomes a single `message` item with one `output_text` content,
    /// tool_use becomes one `function_call` per block, thinking becomes a
    /// `reasoning` item.
    static func outputItems(from blocks: [AnthropicContentBlock]) -> [OutputItem] {
        var outputs: [OutputItem] = []
        var textSegments: [String] = []
        var reasoningSegments: [String] = []

        for block in blocks {
            switch block {
                case let .text(text):
                    textSegments.append(text.text)
                case let .toolUse(toolUse):
                    let arguments = anthropicInputToJSONString(toolUse.input)
                    outputs.append(.functionCall(OutputItem.FunctionCall(
                        id: toolUse.id,
                        callId: toolUse.id,
                        name: toolUse.name,
                        arguments: arguments,
                        status: .completed
                    )))
                case let .thinking(thinking):
                    reasoningSegments.append(thinking.thinking)
                case .image, .toolResult:
                    continue
            }
        }

        if !reasoningSegments.isEmpty {
            outputs.insert(.reasoning(OutputItem.ReasoningOutput(
                id: UUID().uuidString,
                status: .completed,
                summary: [OutputItem.SummaryItem(type: "summary", text: reasoningSegments.joined(separator: "\n"))]
            )), at: 0)
        }

        if !textSegments.isEmpty {
            let text = textSegments.joined(separator: "\n")
            let message = OutputItem.MessageOutput(
                id: UUID().uuidString,
                role: .assistant,
                status: .completed,
                content: [.outputText(OutputItem.OutputText(text: text, annotations: []))]
            )
            outputs.append(.message(message))
        }

        return outputs
    }

    /// Serializes Anthropic's `tool_use.input` (free-form JSON object) into
    /// the JSON-string shape the rest of the codebase passes around for
    /// function-call arguments.
    static func anthropicInputToJSONString(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value),
            let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
