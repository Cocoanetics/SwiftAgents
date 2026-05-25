//
//  Anthropic+Streaming.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.05.26.
//
//  Two transforms live here:
//
//  1. Raw SSE byte stream  → `AnthropicStreamEvent` (native Anthropic events).
//  2. `AnthropicStreamEvent` stream → `ResponsesStreamEvent` stream
//     (the OpenAI-shaped Responses API events the Agents SDK runner expects).

import Foundation
import SwiftMCP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension Anthropic {
    /// Parses Anthropic's SSE byte stream into typed events. Each SSE block has
    /// an `event: <name>` line followed by `data: <json>`. Unknown event
    /// types come through as `.unknown(type:)` so callers can ignore them
    /// gracefully (Anthropic's docs warn that new event types may be added).
    func processAnthropicStream(
        asyncBytes: URLSession.AsyncBytes,
        response: URLResponse
    ) async throws -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            // Drain the body so we can report the error properly.
            let data = try await asyncBytes.reduce(into: Data()) { partialResult, byte in
                partialResult.append(byte)
            }
            throw anthropicError(from: data, response: httpResponse)
        }

        let decoder = self.anthropicDecoder
        return AsyncThrowingStream { continuation in
            Task {
                var currentEvent = ""

                do {
                    for try await line in asyncBytes.lines {
                        // SSE framing has each field starting at column 0:
                        // `event: NAME`, `data: JSON`, blank separator, or
                        // `: comment`. Match by prefix only — substring
                        // matching would misinterpret model output that
                        // happens to contain the literal `event: ` or
                        // `data: ` inside a JSON `data:` payload.
                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst("event: ".count))
                            continue
                        }
                        guard line.hasPrefix("data: ") else {
                            continue
                        }
                        let jsonString = line.dropFirst("data: ".count)
                        guard let jsonData = String(jsonString).data(using: .utf8) else {
                            continue
                        }

                        do {
                            let event = try Anthropic.decode(
                                eventName: currentEvent,
                                data: jsonData,
                                using: decoder
                            )
                            continuation.yield(event)
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Decodes a single SSE event by name. The wire-level shape varies per
    /// event type, so each branch handles its own decoding.
    static func decode(
        eventName: String,
        data: Data,
        using decoder: JSONDecoder
    ) throws -> AnthropicStreamEvent {
        switch eventName {
            case "message_start":
                return try .messageStart(decoder.decode(AnthropicStreamEvent.MessageStart.self, from: data))
            case "content_block_start":
                return try .contentBlockStart(decoder.decode(AnthropicStreamEvent.ContentBlockStart.self, from: data))
            case "content_block_delta":
                return try .contentBlockDelta(decoder.decode(AnthropicStreamEvent.ContentBlockDelta.self, from: data))
            case "content_block_stop":
                return try .contentBlockStop(decoder.decode(AnthropicStreamEvent.ContentBlockStop.self, from: data))
            case "message_delta":
                return try .messageDelta(decoder.decode(AnthropicStreamEvent.MessageDelta.self, from: data))
            case "message_stop":
                return .messageStop
            case "ping":
                return .ping
            case "error":
                let envelope = try decoder.decode(AnthropicErrorResponse.self, from: data)
                return .error(envelope.error)
            default:
                return .unknown(type: eventName)
        }
    }

    // MARK: - Anthropic events → ResponsesStreamEvent

    /// State held while we walk through an Anthropic event stream. Tracks
    /// open content blocks (text vs. tool_use), accumulates text/JSON
    /// deltas, and remembers the message envelope so we can emit a
    /// `responseCompleted` at the end.
    ///
    /// Implemented as an `@unchecked Sendable` class because the entire stream
    /// conversion runs inside a single Task, so we don't need actor isolation
    /// but we do need to satisfy the Sendable requirement of `AsyncThrowingStream`'s
    /// closure.
    final class StreamState: @unchecked Sendable {
        var messageId: String = UUID().uuidString
        var model: String
        var instructions: String?

        /// Information about the currently-open content block. Anthropic only
        /// has one block open at a time and uses an integer `index` to scope
        /// the deltas; we mirror that here so we can correctly attribute
        /// text/tool-arg deltas back to the right output item.
        var currentBlockIndex: Int?
        var currentBlockKind: BlockKind?
        /// Stable id we'll attach to the eventual `output_item.done` event
        /// AND to every delta we yield for this block. For tool_use this is
        /// Anthropic's `toolu_…` id; for text/thinking we mint a fresh UUID
        /// when the block opens so consumers can join deltas to the done
        /// event by `itemId`.
        var currentItemId: String = ""
        var currentText: String = ""
        var currentToolUseId: String = ""
        var currentToolName: String = ""
        var currentToolArguments: String = ""
        var currentThinking: String = ""

        var completedOutputs: [OutputItem] = []
        var stopReason: AnthropicStopReason?
        var usage: AnthropicUsage?

        enum BlockKind {
            case text
            case toolUse
            case thinking
        }

        init(model: String, instructions: String?) {
            self.model = model
            self.instructions = instructions
        }

        func setMessage(id: String, model: String, usage: AnthropicUsage?) {
            messageId = id
            if !model.isEmpty { self.model = model }
            if let usage { self.usage = mergeUsage(into: self.usage, new: usage) }
        }

        func mergeUsage(into existing: AnthropicUsage?, new: AnthropicUsage) -> AnthropicUsage {
            AnthropicUsage(
                inputTokens: new.inputTokens ?? existing?.inputTokens,
                outputTokens: new.outputTokens ?? existing?.outputTokens,
                cacheCreationInputTokens: new.cacheCreationInputTokens ?? existing?.cacheCreationInputTokens,
                cacheReadInputTokens: new.cacheReadInputTokens ?? existing?.cacheReadInputTokens
            )
        }

        func openBlock(index: Int, kind: BlockKind, toolUseId: String = "", toolName: String = "") {
            currentBlockIndex = index
            currentBlockKind = kind
            // tool_use blocks carry Anthropic's id; for text/thinking we
            // synthesise one so every event in the block shares the same id.
            currentItemId = kind == .toolUse ? toolUseId : UUID().uuidString
            currentText = ""
            currentToolUseId = toolUseId
            currentToolName = toolName
            currentToolArguments = ""
            currentThinking = ""
        }

        func appendText(_ delta: String) { currentText += delta }
        func appendToolArguments(_ delta: String) { currentToolArguments += delta }
        func appendThinking(_ delta: String) { currentThinking += delta }

        /// Returns the `OutputItem` for the just-closed block (or nil if the
        /// block kind doesn't translate). Also resets the per-block state.
        func closeBlock() -> OutputItem? {
            defer {
                currentBlockIndex = nil
                currentBlockKind = nil
                currentItemId = ""
                currentText = ""
                currentToolUseId = ""
                currentToolName = ""
                currentToolArguments = ""
                currentThinking = ""
            }

            switch currentBlockKind {
                case .text:
                    let message = OutputItem.MessageOutput(
                        id: currentItemId,
                        role: .assistant,
                        status: .completed,
                        content: [.outputText(OutputItem.OutputText(text: currentText, annotations: []))]
                    )
                    let item = OutputItem.message(message)
                    completedOutputs.append(item)
                    return item

                case .toolUse:
                    let arguments = currentToolArguments.isEmpty ? "{}" : currentToolArguments
                    let item = OutputItem.functionCall(OutputItem.FunctionCall(
                        id: currentItemId,
                        callId: currentItemId,
                        name: currentToolName,
                        arguments: arguments,
                        status: .completed
                    ))
                    completedOutputs.append(item)
                    return item

                case .thinking:
                    let item = OutputItem.reasoning(OutputItem.ReasoningOutput(
                        id: currentItemId,
                        status: .completed,
                        summary: [OutputItem.SummaryItem(type: "summary", text: currentThinking)]
                    ))
                    completedOutputs.append(item)
                    return item

                case nil:
                    return nil
            }
        }

        func setStopReason(_ reason: AnthropicStopReason?) {
            if let reason { stopReason = reason }
        }

        func snapshotResponse(status: ResponseStatus) -> Response {
            Response(
                id: messageId,
                createdAt: Date(),
                completedAt: status == .completed ? Date() : nil,
                status: status,
                background: nil,
                error: nil,
                incompleteDetails: nil,
                instructions: instructions,
                maxOutputTokens: nil,
                model: model,
                output: completedOutputs,
                outputText: nil,
                parallelToolCalls: nil,
                previousResponseId: nil,
                reasoning: nil,
                temperature: nil,
                text: TextConfiguration(format: .text),
                toolChoice: .auto,
                tools: [],
                topP: nil,
                truncation: nil,
                usage: Anthropic.responsesUsage(from: usage),
                user: nil,
                metadata: nil,
                serviceTier: nil
            )
        }
    }

    /// Converts the Anthropic SSE stream into the Responses-API stream the
    /// Agents SDK runner consumes. Key mappings:
    ///
    /// - `message_start`            → `response.created`
    /// - `content_block_start`      → (track block, no event emitted)
    /// - `content_block_delta` text → `response.output_text.delta`
    /// - `content_block_delta` json → `response.function_call_arguments.delta`
    /// - `content_block_stop`       → `response.output_item.done` (with the
    ///                                 fully accumulated item)
    /// - `message_delta`            → carries `stop_reason` / `usage`; we
    ///                                 fold it into the running state
    /// - `message_stop`             → `response.completed`
    static func makeResponsesStream(
        from anthropicStream: AsyncThrowingStream<AnthropicStreamEvent, Error>,
        model: String,
        instructions: String?,
        cacheAssistantTurn: (@Sendable (String, [AnthropicContentBlock]) async -> Void)? = nil
    ) -> AsyncThrowingStream<ResponsesStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let state = StreamState(model: model, instructions: instructions)
                // Accumulate the raw Anthropic content blocks so we can hand
                // the full assistant turn to the conversation cache on
                // message_stop. The Responses-API OutputItems are lossy
                // (e.g. they merge text segments) so we keep both views.
                struct OpenToolUse { var id: String; var name: String; var json: String }
                var assistantBlocks: [AnthropicContentBlock] = []
                var openBlockText: String = ""
                var openBlockToolUse: OpenToolUse?
                var openBlockThinking: String = ""

                do {
                    for try await event in anthropicStream {
                        switch event {
                            case let .messageStart(start):
                                state.setMessage(
                                    id: start.message.id,
                                    model: start.message.model,
                                    usage: start.message.usage
                                )
                                let response = state.snapshotResponse(status: .inProgress)
                                continuation.yield(ResponsesStreamEvent(
                                    type: "response.created",
                                    object: .responseCreated(response)
                                ))

                            case let .contentBlockStart(start):
                                openBlockText = ""
                                openBlockToolUse = nil
                                openBlockThinking = ""
                                switch start.contentBlock {
                                    case let .text(textBlock):
                                        state.openBlock(index: start.index, kind: .text)
                                        state.appendText(textBlock.text)
                                        openBlockText = textBlock.text
                                    case let .toolUse(toolUse):
                                        state.openBlock(
                                            index: start.index,
                                            kind: .toolUse,
                                            toolUseId: toolUse.id,
                                            toolName: toolUse.name
                                        )
                                        openBlockToolUse = OpenToolUse(id: toolUse.id, name: toolUse.name, json: "")
                                    case let .thinking(thinking):
                                        state.openBlock(index: start.index, kind: .thinking)
                                        state.appendThinking(thinking.thinking)
                                        openBlockThinking = thinking.thinking
                                    case .image, .toolResult:
                                        // Not emitted as assistant output.
                                        break
                                }

                            case let .contentBlockDelta(delta):
                                switch delta.delta {
                                    case let .textDelta(text):
                                        state.appendText(text)
                                        openBlockText += text
                                        if let id = state.currentBlockIndex {
                                            let info = ResponsesStreamEvent.OutputTextDeltaInfo(
                                                itemId: state.currentItemId,
                                                outputIndex: id,
                                                contentIndex: 0,
                                                delta: text
                                            )
                                            continuation.yield(ResponsesStreamEvent(
                                                type: "response.output_text.delta",
                                                object: .outputTextDelta(info)
                                            ))
                                        }
                                    case let .inputJsonDelta(json):
                                        state.appendToolArguments(json)
                                        if openBlockToolUse != nil {
                                            openBlockToolUse!.json += json
                                        }
                                        if let id = state.currentBlockIndex {
                                            let info = ResponsesStreamEvent.FunctionCallArgumentsDeltaInfo(
                                                itemId: state.currentItemId,
                                                outputIndex: id,
                                                delta: json
                                            )
                                            continuation.yield(ResponsesStreamEvent(
                                                type: "response.function_call_arguments.delta",
                                                object: .functionCallArgumentsDelta(info)
                                            ))
                                        }
                                    case let .thinkingDelta(thinking):
                                        state.appendThinking(thinking)
                                        openBlockThinking += thinking
                                        if let id = state.currentBlockIndex {
                                            let info = ResponsesStreamEvent.ReasoningTextDeltaInfo(
                                                itemId: state.currentItemId,
                                                outputIndex: id,
                                                contentIndex: 0,
                                                delta: thinking
                                            )
                                            continuation.yield(ResponsesStreamEvent(
                                                type: "response.reasoning_text.delta",
                                                object: .reasoningTextDelta(info)
                                            ))
                                        }
                                    case .signatureDelta, .unknown:
                                        // Signature is verification metadata; not surfaced.
                                        break
                                }

                            case let .contentBlockStop(stop):
                                // Snapshot the just-closed block in Anthropic-native form so we can
                                // hand the assistant turn back to the conversation cache verbatim.
                                if let toolUse = openBlockToolUse {
                                    let jsonString = toolUse.json.isEmpty ? "{}" : toolUse.json
                                    if let data = jsonString.data(using: .utf8),
                                        let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                                        assistantBlocks.append(.toolUse(.init(
                                            id: toolUse.id,
                                            name: toolUse.name,
                                            input: value
                                        )))
                                    } else {
                                        assistantBlocks.append(.toolUse(.init(
                                            id: toolUse.id,
                                            name: toolUse.name,
                                            input: .object([:])
                                        )))
                                    }
                                } else if !openBlockThinking.isEmpty {
                                    assistantBlocks.append(.thinking(.init(thinking: openBlockThinking)))
                                } else if !openBlockText.isEmpty {
                                    assistantBlocks.append(.text(.init(text: openBlockText)))
                                }
                                openBlockText = ""
                                openBlockToolUse = nil
                                openBlockThinking = ""

                                if let item = state.closeBlock() {
                                    let info = ResponsesStreamEvent.OutputItemInfo(
                                        outputIndex: stop.index,
                                        item: item
                                    )
                                    continuation.yield(ResponsesStreamEvent(
                                        type: "response.output_item.done",
                                        object: .outputItemDone(info)
                                    ))
                                }

                            case let .messageDelta(messageDelta):
                                state.setStopReason(messageDelta.delta.stopReason)
                                if let usage = messageDelta.usage {
                                    state.setMessage(id: state.messageId, model: state.model, usage: usage)
                                }

                            case .messageStop:
                                let response = state.snapshotResponse(status: .completed)
                                if let cacheAssistantTurn {
                                    await cacheAssistantTurn(state.messageId, assistantBlocks)
                                }
                                continuation.yield(ResponsesStreamEvent(
                                    type: "response.completed",
                                    object: .responseCompleted(response)
                                ))

                            case .ping, .unknown:
                                continue

                            case let .error(detail):
                                let errorDetail = ErrorDetail(
                                    message: detail.message,
                                    type: detail.type
                                )
                                continuation.yield(ResponsesStreamEvent(
                                    type: "error",
                                    object: .error(errorDetail)
                                ))
                                continuation.finish(throwing: APIError.apiError(detail.message))
                                return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
