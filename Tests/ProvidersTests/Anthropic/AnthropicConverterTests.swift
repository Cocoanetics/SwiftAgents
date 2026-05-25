//
//  AnthropicConverterTests.swift
//  ProvidersTests
//
//  Offline tests for the Anthropic <-> SwiftAgents type converters. These
//  don't hit the network so they run on every PR; the integration tests in
//  AnthropicIntegrationTests are gated on ANTHROPIC_API_KEY.
//

import Foundation
@testable import Providers
import SwiftMCP
import Testing

struct AnthropicConverterTests {
    // MARK: - ChatMessage → Anthropic

    @Test("System messages are extracted into the system prompt")
    func systemPromptExtraction() {
        let messages: [ChatMessage] = [
            .init(role: .system, content: .text("Be concise.")),
            .init(role: .user, content: .text("Hi"))
        ]
        let (system, anthropicMessages) = Anthropic.convertChatMessages(messages)

        if case let .text(text)? = system {
            #expect(text == "Be concise.")
        } else {
            Issue.record("Expected system text, got \(String(describing: system))")
        }
        #expect(anthropicMessages.count == 1)
        #expect(anthropicMessages.first?.role == .user)
    }

    @Test("Multiple system messages are joined")
    func multipleSystemMessages() {
        let messages: [ChatMessage] = [
            .init(role: .system, content: .text("Rule 1")),
            .init(role: .developer, content: .text("Rule 2")),
            .init(role: .user, content: .text("Go"))
        ]
        let (system, _) = Anthropic.convertChatMessages(messages)

        if case let .text(text)? = system {
            #expect(text.contains("Rule 1"))
            #expect(text.contains("Rule 2"))
        } else {
            Issue.record("Expected joined system text")
        }
    }

    @Test("Tool result messages are folded into a user message with tool_result")
    func toolResultFolding() throws {
        let messages: [ChatMessage] = [
            .init(role: .user, content: .text("Run the tool")),
            .init(
                role: .assistant,
                content: .text(""),
                toolCalls: [
                    ToolCall(
                        id: "toolu_123",
                        type: "function",
                        function: FunctionCall(name: "get_weather", arguments: "{}")
                    )
                ]
            ),
            .init(role: .tool, content: .text("sunny"), toolCallID: "toolu_123")
        ]

        let (_, anthropicMessages) = Anthropic.convertChatMessages(messages)

        // Expect: user("Run the tool"), assistant(tool_use), user(tool_result)
        #expect(anthropicMessages.count == 3)
        let last = try #require(anthropicMessages.last)
        #expect(last.role == .user)
        guard case let .blocks(blocks) = last.content else {
            Issue.record("Expected blocks content")
            return
        }
        guard case let .toolResult(result) = blocks.first else {
            Issue.record("Expected tool_result block as first element")
            return
        }
        #expect(result.toolUseId == "toolu_123")
        if case let .text(text) = result.content {
            #expect(text == "sunny")
        }
    }

    @Test("Image data URLs become base64 image blocks")
    func imageDataURLConversion() throws {
        let data = Data([0xFF, 0xD8, 0xFF])
        let part = ChatMessage.ContentPart.imageDataPart(mimeType: "image/jpeg", data: data)
        let message = ChatMessage(role: .user, content: .parts([part]))

        let (_, anthropicMessages) = Anthropic.convertChatMessages([message])
        let first = try #require(anthropicMessages.first)
        guard case let .blocks(blocks) = first.content else {
            Issue.record("Expected blocks content")
            return
        }
        guard case let .image(image) = blocks.first else {
            Issue.record("Expected image block")
            return
        }
        #expect(image.source.type == "base64")
        #expect(image.source.mediaType == "image/jpeg")
        #expect(image.source.data == data.base64EncodedString())
    }

    // MARK: - Response.Input → Anthropic

    @Test("Response.Input plain text becomes a user message")
    func responseInputText() throws {
        let (system, messages) = Anthropic.convertResponseInput(.text("Hello"), instructions: "Be brief.")
        if case let .text(text)? = system {
            #expect(text == "Be brief.")
        } else {
            Issue.record("Expected system text")
        }
        let first = try #require(messages.first)
        #expect(first.role == .user)
        if case let .text(text) = first.content {
            #expect(text == "Hello")
        }
    }

    @Test("Response.Input function call output becomes tool_result")
    func responseInputFunctionCallOutput() throws {
        let elements: [Response.Input.Element] = [
            .functionCallOutput(FunctionCallOutput(callId: "call_42", output: "42"))
        ]
        let (_, messages) = Anthropic.convertResponseInput(.array(elements), instructions: nil)
        let first = try #require(messages.first)
        #expect(first.role == .user)
        guard case let .blocks(blocks) = first.content,
            case let .toolResult(result) = blocks.first else {
            Issue.record("Expected tool_result block")
            return
        }
        #expect(result.toolUseId == "call_42")
        if case let .text(text) = result.content {
            #expect(text == "42")
        }
    }

    // MARK: - Tool conversions

    @Test("Function tools become Anthropic tool declarations")
    func toolConversion() throws {
        let tool = Tool.function(FunctionTool(
            name: "get_weather",
            description: "Get the weather",
            parameters: Parameters(properties: [
                "location": .string(description: "City")
            ], required: ["location"]),
            strict: false
        ))
        let converted = Anthropic.convertTools([tool])
        let first = try #require(converted?.first)
        #expect(first.name == "get_weather")
        #expect(first.description == "Get the weather")
        #expect(first.inputSchema.properties.keys.contains("location"))
    }

    @Test("Tool choice .auto maps to Anthropic auto")
    func toolChoiceAuto() {
        guard case .auto = Anthropic.convertToolChoice(.auto) else {
            Issue.record("Expected .auto")
            return
        }
    }

    @Test("Tool choice .required maps to Anthropic any")
    func toolChoiceRequired() {
        guard case .any = Anthropic.convertToolChoice(.required) else {
            Issue.record("Expected .any")
            return
        }
    }

    // MARK: - Response Mapping

    @Test("Anthropic text content becomes an OutputItem.message")
    func textResponseMapping() throws {
        let response = AnthropicMessagesResponse(
            id: "msg_1",
            model: "claude-opus-4-7",
            content: [.text(AnthropicTextBlock(text: "Hello!"))],
            stopReason: .endTurn,
            stopSequence: nil,
            usage: AnthropicUsage(inputTokens: 10, outputTokens: 5)
        )
        let mapped = Anthropic.makeResponse(model: "claude-opus-4-7", instructions: nil, response: response)
        #expect(mapped.output.count == 1)
        guard case let .message(message) = mapped.output.first else {
            Issue.record("Expected message output item")
            return
        }
        guard case let .outputText(text) = message.content.first else {
            Issue.record("Expected output_text content")
            return
        }
        #expect(text.text == "Hello!")
        #expect(mapped.usage?.inputTokens == 10)
        #expect(mapped.usage?.outputTokens == 5)
    }

    @Test("Anthropic tool_use becomes an OutputItem.functionCall")
    func toolUseResponseMapping() throws {
        let response = AnthropicMessagesResponse(
            id: "msg_2",
            model: "claude-opus-4-7",
            content: [
                .toolUse(AnthropicToolUseBlock(
                    id: "toolu_1",
                    name: "get_weather",
                    input: .object(["location": .string("SF")])
                ))
            ],
            stopReason: .toolUse,
            stopSequence: nil,
            usage: nil
        )
        let mapped = Anthropic.makeResponse(model: "claude-opus-4-7", instructions: nil, response: response)
        guard case let .functionCall(call) = mapped.output.first else {
            Issue.record("Expected function_call output")
            return
        }
        #expect(call.callId == "toolu_1")
        #expect(call.name == "get_weather")
        #expect(call.arguments.contains("SF"))
    }

    @Test("Stop reasons map to OpenAI-shaped finish reasons")
    func stopReasonMapping() {
        #expect(Anthropic.chatFinishReason(from: .endTurn) == .stop)
        #expect(Anthropic.chatFinishReason(from: .maxTokens) == .limit)
        #expect(Anthropic.chatFinishReason(from: .toolUse) == .toolCalls)
        #expect(Anthropic.chatFinishReason(from: .refusal) == .contentFilter)
    }
}
