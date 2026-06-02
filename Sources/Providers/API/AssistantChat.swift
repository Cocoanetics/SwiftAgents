//
//  AssistantChat.swift
//
//
//  Created by Oliver Drobnik on 19.05.24.
//

import Foundation
import SwiftMCP

/// Same as Chat, but with an Assistant instead
public class AssistantChat: GenericChat {
    public let model: String
    let api: OpenAI

    let systemPrompt: String

    public var messages: [MessageCreation]?
    public var assistant: Assistant!
    public var thread: Thread!

    /// the temperature used for all chat completion requests
    let temperature: Double

    /// Tool providers
    let tools: [MCPToolProviding]?

    public var stream: Bool = true

    public weak var delegate: ChatDelegate?

    public init(
        api: OpenAI,
        model: String,
        systemPrompt: String,
        temperature: Double = 0.7,
        stream: Bool = false,
        tools: [MCPToolProviding]? = nil
    ) {
        self.api = api
        self.model = model
        self.tools = tools
        self.temperature = temperature
        self.stream = stream
        self.systemPrompt = systemPrompt
    }

    public init(api: OpenAI, chatCompletionRequest: ChatCompletionRequest, tools: [MCPToolProviding]? = nil) {
        self.api = api
        model = chatCompletionRequest.model
        self.tools = tools
        stream = chatCompletionRequest.stream ?? true
        temperature = chatCompletionRequest.temperature ?? 1

        var messages = chatCompletionRequest.messages

        if let index = messages.firstIndex(where: { $0.role == .system }) {
            systemPrompt = messages[index].textContent ?? ""
            messages.remove(at: index)
        } else {
            systemPrompt = "You are a helpful assistent"
        }

        self.messages = messages.map { chatMessage in
            MessageCreation(role: chatMessage.role, content: chatMessage.textContent ?? "")
        }
    }

    public func sendMessage(_ message: String, user _: String) async throws {
        try await setupIfNecessary()

        try await api.createMessage(threadId: thread.id, role: .user, content: message)

        if stream {
            let stream = try await api.createRunStream(threadId: thread.id, assistantId: assistant.id)
            try await handleRunStream(stream)
        } else {
            let run = try await api.createRun(threadId: thread.id, assistantId: assistant.id)

            try await handleRun(run)
        }
    }

    // MARK: - Helpers

    public func setupIfNecessary(assistantID: String? = nil, threadID: String? = nil) async throws {
        guard assistant == nil, thread == nil else {
            return
        }

        if let assistantID {
            assistant = try await api.retrieveAssistant(id: assistantID)
        } else {
            var toolDescriptions = [ToolDescription.fileSearch, ToolDescription.codeInterpreter]

            if let tools {
                toolDescriptions += await tools.toolDescriptions
            }

            assistant = try await api.createAssistant(
                model: model,
                instructions: systemPrompt,
                tools: toolDescriptions,
                temperature: temperature
            )
        }

        if let threadID {
            thread = try await api.retrieveThread(id: threadID)
        } else {
            thread = try await api.createThread(messages: messages)
        }
    }

    fileprivate func handleRun(_ run: Run) async throws {
        repeat {
            var run = try await api.waitUntilRunIsFinished(threadId: run.threadId, runId: run.id, interval: 1)

            if run.status != .requiresAction {
                break
            }

            if let toolCalls = run.requiredAction?.submitToolOutputs?.toolCalls, let tools {
                delegate?.chat(self, didReceiveToolCalls: toolCalls)

                let outputs = await tools.perform(toolCalls)

                run = try await api.submitToolOutputs(toThreadId: thread.id, runId: run.id, toolOutputs: outputs)
            }
        } while run.requiredAction != nil || ![.cancelled, .failed, .completed, .expired].contains(run.status)

        let messages = try await api.listMessages(threadId: thread.id, runId: run.id)

        if let latestMessage = messages.data.first {
            for content in latestMessage.content {
                switch content {
                    case let .image(file):
                        try await delegate?.chat(self, didReceive: file)

                    case let .text(textContent):
                        delegate?.chat(
                            self,
                            didReceiveMessage: textContent.value,
                            role: latestMessage.role,
                            isComplete: true
                        )
                }
            }
        }
    }

    fileprivate func handleImageFile(_ imageFile: ImageFile) async throws -> (File, Data) {
        let meta = try await api.retrieveFile(id: imageFile.fileId)
        let data = try await api.retrieveFileContent(id: imageFile.fileId)

        return (meta, data)
    }

    fileprivate func handleRunStream(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws {
        var buffer: String!

        for try await event in stream {
            switch event.object {
                case let .run(run):
                    if run.status == .requiresAction,
                        let toolCalls = run.requiredAction?.submitToolOutputs?.toolCalls,
                        let tools {
                        delegate?.chat(self, didReceiveToolCalls: toolCalls)

                        let outputs = await tools.perform(toolCalls)

                        let stream = try await api.submitToolOutputsStream(
                            toThreadId: thread.id,
                            runId: run.id,
                            toolOutputs: outputs
                        )
                        return try await handleRunStream(stream)
                    }

                case let .message(message):
                    if !self.stream {
                        for content in message.content {
                            switch content {
                                case let .image(file):
                                    try await delegate?.chat(self, didReceive: file)

                                case let .text(textContent):
                                    if textContent.value == "![" {
                                        buffer = textContent.value
                                    } else if buffer != nil {
                                        buffer.append(textContent.value)

                                        if buffer.contains(")") {
                                            // flush entire image tag
                                            delegate?.chat(
                                                self,
                                                didReceiveMessage: buffer,
                                                role: .assistant,
                                                isComplete: false
                                            )
                                            buffer = nil
                                        }
                                    } else {
                                        delegate?.chat(
                                            self,
                                            didReceiveMessage: textContent.value,
                                            role: .assistant,
                                            isComplete: false
                                        )
                                    }
                            }
                        }
                    }

                    // print(message)

                    if message.status == .completed {
                        delegate?.chat(self, didReceiveMessage: "", role: .assistant, isComplete: true)
                    }

                case let .messageDelta(delta):
                    if self.stream {
                        for content in delta.delta.content {
                            switch content {
                                case let .image(file):
                                    try await delegate?.chat(self, didReceive: file)

                                case let .text(textContent):
                                    if textContent.value == "![" {
                                        buffer = textContent.value
                                    } else if buffer != nil {
                                        buffer.append(textContent.value)

                                        if buffer.contains(")") {
                                            // flush entire image tag
                                            delegate?.chat(
                                                self,
                                                didReceiveMessage: buffer,
                                                role: .assistant,
                                                isComplete: false
                                            )
                                            buffer = nil
                                        }
                                    } else {
                                        delegate?.chat(
                                            self,
                                            didReceiveMessage: textContent.value,
                                            role: .assistant,
                                            isComplete: false
                                        )
                                    }
                            }
                        }
                    }

                default:
                    break
            }
        }
    }
}
