//
//  OllamaAPI.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 19.04.24.
//

import Foundation

public class OllamaAPI: API, @unchecked Sendable {
    // MARK: - Chat Completions

    override public func createChatCompletion(
        model: String,
        messages: [ChatMessage],
        tools: [ToolDescription]? = nil,
        toolChoice: ToolChoice? = nil,
        n: Int? = nil,
        stop: [String]? = nil,
        store _: Bool? = nil,
        temperature: Double? = nil,
        maxCompletionTokens: Int? = nil,
        metadata: [String: String]? = nil,
        parallelToolCalls: Bool? = nil,
        presencePenalty: Double? = nil,
        responseFormat: ChatCompletionRequest.ResponseFormat? = nil,
        frequencyPenalty: Double? = nil,
        logitBias: [String: Int]? = nil,
        user: String? = nil
    ) async throws -> ChatCompletionResponse {
        // inject the tools description into the system prompt
        let messages = inject(tools: tools, messages: messages)

        var response = try await super.createChatCompletion(
            model: model,
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            n: n,
            stop: stop,
            temperature: temperature,
            maxCompletionTokens: maxCompletionTokens,
            metadata: metadata,
            parallelToolCalls: parallelToolCalls,
            presencePenalty: presencePenalty,
            responseFormat: responseFormat,
            frequencyPenalty: frequencyPenalty,
            logitBias: logitBias,
            user: user
        )

        let choices = response.choices.map { choice in
            guard let content = choice.message.textContent,
                let functionCalls = content.extractFunctionCalls() else {
                return choice
            }

            var modifiedMessage = choice.message

            let toolCalls = functionCalls.map { ToolCall(id: $0.name, type: "function", function: $0) }
            modifiedMessage.toolCalls = toolCalls

            var newContent = "Please respond with the results to these tool calls:\n\n"

            for functionCall in functionCalls {
                newContent += " - \(functionCall.description)\n"
            }

            modifiedMessage.content = .text(newContent)

            return ChatCompletionResponse.Choice(
                message: modifiedMessage,
                finishReason: .toolCalls,
                index: choice.index
            )
        }

        response.choices = choices

        return response
    }

    override public func createChatCompletionStream(
        model: String,
        messages: [ChatMessage],
        tools: [ToolDescription]? = nil,
        toolChoice: ToolChoice? = nil,
        n: Int = 1,
        streamOptions: ChatCompletionRequest.StreamOptions? = nil,
        stop: [String]? = nil,
        store _: Bool? = nil,
        temperature: Double? = nil,
        maxCompletionTokens: Int? = nil,
        metadata: [String: String]? = nil,
        parallelToolCalls: Bool? = nil,
        presencePenalty: Double = 0.0,
        responseFormat: ChatCompletionRequest.ResponseFormat? = nil,
        frequencyPenalty: Double = 0.0,
        logitBias: [String: Int]? = nil,
        user: String? = nil
    ) async throws -> AsyncThrowingStream<Chunk, Error> {
        // inject the tools description into the system prompt
        let messages = inject(tools: tools, messages: messages)

        return try await super.createChatCompletionStream(
            model: model,
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            n: n,
            streamOptions: streamOptions,
            stop: stop,
            temperature: temperature,
            maxCompletionTokens: maxCompletionTokens,
            metadata: metadata,
            parallelToolCalls: parallelToolCalls,
            presencePenalty: presencePenalty,
            responseFormat: responseFormat,
            frequencyPenalty: frequencyPenalty,
            logitBias: logitBias,
            user: user
        )
    }

    // MARK: - Embeddings

    /// When generating embeddings via the Ollama API this is the embedding model to use
    public var embeddingModelIdentifier: String = "mxbai-embed-large"

    public func embedding(input: String, model: String) async throws -> Vector {
        let embeddingRequest = OllamaEmbeddingRequest(prompt: input, model: model)
        let request = try createUrlRequest(httpMethod: "POST", path: "/api/embeddings", body: embeddingRequest)

        let (data, response) = try await session.data(for: request)

        let embeddingResponse: OllamaEmbeddingResponse = try process(data: data, response: response)
        return embeddingResponse.embedding
    }

    /// decoder for decoding objects from Ollama `/api/` endpoints
    public lazy var ollamaDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder -> Date in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            // Create date formatter
            let formatter = DateFormatter()
            formatter
                .dateFormat =
                "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSSXXXXX" // ISO 8601 format with milliseconds and timezone offset
            formatter.locale = Locale(identifier: "en_US_POSIX") // Ensure consistent date formatting

            if let date = formatter.date(from: dateString) {
                return date
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateString)")
            }
        }
        return decoder
    }()

    override public func models() async throws -> [Model] {
        let request = try createUrlRequest(path: "/api/tags")
        let (data, _) = try await session.data(for: request)

        do {
            let listResponse = try ollamaDecoder.decode(OllamaModelListResponse.self, from: data)

            return listResponse.models.map { ollamaModel in
                return Model(
                    id: ollamaModel.name,
                    object: nil,
                    created: ollamaModel.modifiedAt,
                    ownedBy: nil,
                    permission: nil,
                    root: nil,
                    parent: nil
                )
            }

        } catch {
            print(error)
        }

        return []
    }

    // MARK: - Helpers

    fileprivate func inject(tools: [ToolDescription]?, messages: [ChatMessage]) -> [ChatMessage] {
        guard let toolsWithFunction = tools?.filter({ $0.function != nil }),
            !toolsWithFunction.isEmpty else {
            return messages
        }

        return messages.map { message in
            guard message.role == .system else {
                return message
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted

            let functions = toolsWithFunction.compactMap(\.function)

            let modifiedContent = (message.textContent ?? "") +
                """
                \n\nThe following tools are available to call in lieu of asking the user for this information.

                \(functions.asJSON())

                To call a function just

                1. output the tool call in JSON format
                2. NO additional text besides the function call itself
                3. DO NOT include descriptions of function or parameters
                4. Make the JSON as compact as possible.

                Example: `{ "tool": "function", "tool_input": { "param": "value" } }`

                """

            return ChatMessage(role: .system, content: .text(modifiedContent))
        }
    }
}
