//
//  Chat.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 15.06.23.
//

import Foundation
import SwiftMCP

public class Chat: GenericChat {
    public private(set) var messages = [ChatMessage]()
    var usages = [Usage]()

    public var totalUsage: Usage {
        var total = Usage()

        for usage in usages {
            total.completionTokens += usage.completionTokens
            total.promptTokens += usage.promptTokens
            total.totalTokens += usage.totalTokens
        }

        return total
    }

    public let tools: [any MCPToolProviding]?
    public let model: String
    let api: API

    /// the temperature used for all chat completion requests
    var temperature: Double?

    public var stream: Bool = true
    public var store: Bool?
    public weak var delegate: ChatDelegate?

    public init(
        api: API,
        model: String,
        systemPrompt: String,
        temperature: Double? = nil,
        stream: Bool = false,
        store: Bool,
        tools: [MCPToolProviding]? = nil
    ) {
        self.api = api
        self.model = model
        self.tools = tools
        self.temperature = temperature
        self.stream = stream
        self.store = store

        if !systemPrompt.isEmpty {
            let message = ChatMessage(role: .system, content: .text(systemPrompt))
            messages.append(message)
        }
    }

    public func sendMessage(_ message: String, user: String) async throws {
        let message = ChatMessage(role: .user, content: .text(message), name: user)
        messages.append(message)

        try await commonSend()
    }

    fileprivate func commonSend() async throws {
        if let rateLimit = api.rateLimit, rateLimit.isRateLimited {
            delegate?.chat(self, rateLimitExceededUntil: rateLimit.requestsResetDate)
        }

        switch stream {
            case true:
                let tools = tools?.flatMap(\.toolDescriptions)
                let stream = try await api.createChatCompletionStream(
                    model: model,
                    messages: messages,
                    tools: tools,
                    streamOptions: .includeUsage(true),
                    store: store,
                    temperature: temperature
                )
                let assembler = ChatCompletionAssembler()

                // Iterate through the stream to collect the response chunks
                for try await chunk in stream {
                    assembler.processChunk(chunk)

                    if let choice = chunk.choices.first, let message = choice.delta.content {
                        delegate?.chat(self, didReceiveMessage: message, role: .assistant, isComplete: false)
                    }
                }

                // end of stream
                try await handleResponse(assembler.response)

            case false:
                let tools = tools?.flatMap(\.toolDescriptions)
                let response = try await api.createChatCompletion(
                    model: model,
                    messages: messages,
                    tools: tools,
                    store: store,
                    temperature: temperature
                )

                if let choice = response.choices.first {
                    delegate?.chat(self, didReceive: choice.message)

                    if let text = choice.message.textContent {
                        delegate?.chat(self, didReceiveMessage: text, role: choice.message.role, isComplete: true)
                    }
                }

                try await handleResponse(response)
        }
    }

    fileprivate func handleResponse(_ response: ChatCompletionResponse) async throws {
        if let usage = response.usage {
            usages.append(usage)
        }

        guard let choice = response.choices.first else {
            preconditionFailure()
        }

        messages.append(choice.message)

        switch choice.finishReason {
            case .stop:
                if let tools {
                    var responses = [ChatMessage]()

                    if let content = choice.message.textContent,
                        let calls = content.extractFunctionCalls() {
                        let toolCalls = calls.map { ToolCall(id: $0.name, type: "function", function: $0) }

                        for toolCall in toolCalls {
                            guard let functionCall = toolCall.function else {
                                continue
                            }

                            let output = await tools.perform(toolCall)

                            let message = messageResponding(
                                to: functionCall,
                                role: .function,
                                toolCallID: output.toolCallId,
                                value: output.output
                            )
                            responses.append(message)
                        }
                    } else if let toolCalls = choice.message.toolCalls {
                        delegate?.chat(self, didReceiveToolCalls: toolCalls)

                        for toolCall in choice.message.toolCalls ?? [] {
                            guard let functionCall = toolCall.function else {
                                continue
                            }

                            let output = await tools.perform(toolCall)

                            let message = messageResponding(
                                to: functionCall,
                                role: .tool,
                                toolCallID: output.toolCallId,
                                value: output.output
                            )
                            responses.append(message)
                        }
                    }

                    if !responses.isEmpty {
                        for response in responses {
                            messages.append(response)
                            delegate?.chat(self, didReceive: response)
                        }

                        try await commonSend()
                    }

                } else {
                    if stream {
                        delegate?.chat(self, didReceiveMessage: "", role: .assistant, isComplete: true)
                    }
                }

            case .limit, .contentFilter:
                break

            case .functionCall:
                if let tools,
                    let functionCall = choice.message.functionCall {
                    let toolCall = ToolCall(id: functionCall.name, type: "function", function: functionCall)

                    let output = await tools.perform(toolCall)

                    let message = messageResponding(
                        to: functionCall,
                        role: .tool,
                        toolCallID: output.toolCallId,
                        value: output.output
                    )
                    messages.append(message)

                    delegate?.chat(self, didReceive: message)

                    try await commonSend()
                }

            case .toolCalls:
                guard let tools else {
                    return
                }

                var responses = [ChatMessage]()

                if let toolCalls = choice.message.toolCalls {
                    delegate?.chat(self, didReceiveToolCalls: toolCalls)

                    for toolCall in choice.message.toolCalls ?? [] {
                        guard let functionCall = toolCall.function else {
                            continue
                        }

                        let output = await tools.perform(toolCall)
                        let message = messageResponding(
                            to: functionCall,
                            role: .tool,
                            toolCallID: output.toolCallId,
                            value: output.output
                        )
                        responses.append(message)
                    }

                    if !responses.isEmpty {
                        for response in responses {
                            messages.append(response)
                            delegate?.chat(self, didReceive: response)
                        }

                        try await commonSend()
                    }
                }

            case .none:
                break
        }
    }

    fileprivate func messageResponding(
        to functionCall: FunctionCall,
        role: Role,
        toolCallID: String? = nil,
        value: String
    ) -> ChatMessage {
        if let toolCallID, !toolCallID.isEmpty {
            return ChatMessage(role: role, content: .text(value), name: nil, toolCallID: toolCallID)
        } else {
            let response =
                """
                \(functionCall.description) =

                ```
                \(value)
                ```
                """
            return ChatMessage(role: .user, content: .text(response), name: functionCall.name)
        }
    }
}
