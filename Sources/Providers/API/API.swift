//
// 	API.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 08.05.23.
//

import Foundation
import Tracing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension URL {
    /// Default endpoint URL for the OpenAI Chat endpoint
    static let openAI = URL(string: "https://api.openai.com")!

    /// Default endpoint URL for the Google AI API endpoint
    static let googleAI = URL(string: "https://generativelanguage.googleapis.com")!
}

open class API: @unchecked Sendable {
    let apiKey: String?
    let endpointURL: URL
    let session: URLSession

    let versionPath: String

    /// How the Runner should handle conversation state and tracing for this
    /// provider. Default: stateless (client sends full history, spans emit
    /// `GenerationSpanData`). Subclasses override to opt into server-side
    /// history chaining and/or OpenAI-routable response ids.
    open var statePolicy: ConversationStatePolicy { .stateless }

    public lazy var encoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = JSONEncoder.KeyEncodingStrategy.custom { codingPath in
            guard let last = codingPath.last else { return AnyKey(stringValue: "") }

            // avoid snake case in JSON schema
            if codingPath.contains(where: { ["schema", "tools"].contains($0.stringValue) }) {
                return last
            } else {
                // Convert to snake_case
                let snake = last.stringValue.replacingOccurrences(
                    of: "([a-z0-9])([A-Z])",
                    with: "$1_$2",
                    options: .regularExpression
                ).lowercased()
                if let intValue = last.intValue {
                    return AnyKey(intValue: intValue)
                } else {
                    return AnyKey(stringValue: snake)
                }
            }
        }
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.dataEncodingStrategy = .base64
        encoder.outputFormatting = .prettyPrinted
        return encoder
    }()

    public lazy var decoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = JSONDecoder.KeyDecodingStrategy.custom { codingPath in
            guard let last = codingPath.last else { return AnyKey(stringValue: "") }

            if codingPath.contains(where: { ["schema", "tools"].contains($0.stringValue) }) {
                return last
            } else {
                // Convert from snake_case to camelCase
                let components = last.stringValue.split(separator: "_")
                let camel = components.enumerated().map { idx, part in
                    idx == 0 ? String(part) : part.capitalized
                }.joined()
                if let intValue = last.intValue {
                    return AnyKey(intValue: intValue)
                } else {
                    return AnyKey(stringValue: camel)
                }
            }
        }
        decoder.dateDecodingStrategy = .secondsSince1970
        decoder.dataDecodingStrategy = .base64
        return decoder
    }()

    /// Helper struct for custom key strategies
    fileprivate struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(stringValue: String) {
            self.stringValue = stringValue; intValue = nil
        }

        init(intValue: Int) {
            stringValue = "\(intValue)"; self.intValue = intValue
        }
    }

    public var streamingChunkHandler: (Chunk) -> Void = { _ in
    }

    // MARK: - Initialization

    public init(apiKey: String? = nil, endpointURL: URL = .openAI, versionPath: String = "v1") {
        self.apiKey = apiKey
        self.endpointURL = endpointURL
        self.versionPath = versionPath

        // Create a URLSessionConfiguration
        let configuration = URLSessionConfiguration.default
        // Set the timeout interval for the request (in seconds)
        configuration.timeoutIntervalForRequest = 360 // For example, 30 seconds
        configuration.timeoutIntervalForResource = 360

        // Create a URLSession with the configuration
        session = URLSession(configuration: configuration)
    }

    // MARK: - Models

    public func models() async throws -> [Model] {
        let request = try createUrlRequest(path: "/\(versionPath)/models")
        let (data, response) = try await session.data(for: request)

        let listResponse: ModelListResponse = try process(data: data, response: response)
        return listResponse.data
    }

    // MARK: - Chat Completions

    /**
     Creates a chat completion using the specified parameters.

     - Parameters:
     - model: The ID of the model to use for generating the response. (Required)
     - messages: A list of messages describing the conversation so far. (Required)
     - tools: The local functions GPT can call. (Optional)
     - n: The number of chat completion choices to generate for each input message. (Optional, defaults to 1)
     - stop: Up to 4 sequences where the API will stop generating further tokens. (Optional)
     - temperature: What sampling temperature to use, between 0 and 2. (Optional, defaults to 1)
     - maxTokens: The maximum number of tokens to generate in the chat completion. (Optional)
     - presencePenalty: Number between -2.0 and 2.0. Positive values penalize new tokens based on whether they appear in the text so far. (Optional, defaults to 0)
     - responseFormat: An object specifying the format that the model must output. (Optional)
     - frequencyPenalty: Number between -2.0 and 2.0. Positive values penalize new tokens based on their existing frequency in the text so far. (Optional, defaults to 0)
     - logitBias: Modify the likelihood of specified tokens appearing in the completion. (Optional)
     - user: A unique identifier representing your end-user. (Optional)

     - Returns: An instance of `ChatCompletionResponse` containing the response from the API.

     - Throws: An error if the request fails or the response is invalid.

     - See also: [OpenAI API Documentation](https://platform.openai.com/docs/api-reference/chat/create)
     */
    public func createChatCompletion(
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
        // Check rate limits before proceeding
        if let rateLimit {
            await rateLimit.waitForRateLimitReset()
        }

        let chatCompletionRequest = ChatCompletionRequest(
            model: model,
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            n: n,
            stream: false,
            temperature: temperature,
            stop: stop,
            store: nil,
            maxCompletionTokens: maxCompletionTokens,
            metadata: metadata,
            parallelToolCalls: parallelToolCalls,
            presencePenalty: presencePenalty,
            responseFormat: responseFormat,
            frequencyPenalty: frequencyPenalty,
            logitBias: logitBias,
            user: user
        )

        let endpoint = "/\(versionPath)/chat/completions"
        let request = try createUrlRequest(httpMethod: "POST", path: endpoint, body: chatCompletionRequest)

        // logHttpRequest(request)

        let (data, response) = try await session.data(for: request)

        return try process(data: data, response: response)
    }

    func logHttpRequest(_ request: URLRequest) {
        // Log the HTTP method and URL
        let httpMethod = request.httpMethod ?? "UNKNOWN METHOD"
        let url = request.url?.absoluteString ?? "UNKNOWN URL"
        NSLog("HTTP Request: %@ %@", httpMethod, url)

        // Log headers
        if let headers = request.allHTTPHeaderFields {
            NSLog("Headers: %@", headers.description)
        } else {
            NSLog("No headers")
        }

        // Log the body
        if let body = request.httpBody,
            let json = try? JSONSerialization.jsonObject(with: body, options: []),
            let prettyJsonData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
            let prettyJsonString = String(data: prettyJsonData, encoding: .utf8) {
            NSLog("Body: %@", prettyJsonString)
        } else if let body = request.httpBody,
            let plainText = String(data: body, encoding: .utf8) {
            NSLog("Body: %@", plainText)
        } else {
            NSLog("No body or unreadable body")
        }
    }

    /**
     Creates a chat completion stream using the specified parameters.

     - Parameters:
     - model: The ID of the model to use for generating the response. (Required)
     - messages: A list of messages describing the conversation so far. (Required)
     - tools: The local functions GPT can call. (Optional)
     - n: The number of chat completion choices to generate for each input message. (Optional, defaults to 1)
     - streamOptions: Options for streaming response, only applicable when stream is true. (Optional)
     - stop: Up to 4 sequences where the API will stop generating further tokens. (Optional)
     - temperature: What sampling temperature to use, between 0 and 2. (Optional, defaults to 1)
     - maxCompletionTokens: The maximum number of tokens to generate in the chat completion. (Optional)
     - presencePenalty: Number between -2.0 and 2.0. Positive values penalize new tokens based on whether they appear in the text so far. (Optional, defaults to 0)
     - responseFormat: The format that the model must output. (Optional, defaults to .text)
     - frequencyPenalty: Number between -2.0 and 2.0. Positive values penalize new tokens based on their existing frequency in the text so far. (Optional, defaults to 0)
     - logitBias: Modify the likelihood of specified tokens appearing in the completion. (Optional)
     - user: A unique identifier representing your end-user. (Optional)

     - Returns: An instance of `AsyncThrowingStream<Chunk, Error>` containing the response from the API as a stream.

     - Throws: An error if the request fails or the response is invalid.

     - See also: [OpenAI API Documentation](https://platform.openai.com/docs/api-reference/chat/create)
     */
    public func createChatCompletionStream(
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
        // Check rate limits before proceeding
        if let rateLimit {
            await rateLimit.waitForRateLimitReset()
        }

        let chatCompletionRequest = ChatCompletionRequest(
            model: model,
            messages: messages,
            tools: tools,
            toolChoice: toolChoice,
            n: n,
            stream: true,
            streamOptions: streamOptions,
            temperature: temperature,
            stop: stop,
            store: nil,
            maxCompletionTokens: maxCompletionTokens,
            metadata: metadata,
            parallelToolCalls: parallelToolCalls,
            presencePenalty: presencePenalty,
            responseFormat: responseFormat,
            frequencyPenalty: frequencyPenalty,
            logitBias: logitBias,
            user: user
        )

        let endpoint = "/\(versionPath)/chat/completions"
        let request = try createUrlRequest(httpMethod: "POST", path: endpoint, body: chatCompletionRequest)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        return try await processStream(asyncBytes: asyncBytes, response: response)
    }

    // MARK: - Rate Limit

    /// Store rate limit information
    public private(set) var rateLimit: RateLimit?

    // MARK: - Helpers

    open func createUrlRequest(
        httpMethod: String = "GET",
        path: String,
        body: Codable? = nil,
        queryItems: [URLQueryItem]? = nil
    ) throws -> URLRequest {
        // Create the URL from the base endpoint and the specific path.
        guard var urlComponents = URLComponents(url: endpointURL.appending(path: path), resolvingAgainstBaseURL: true)
        else {
            throw URLError(.badURL)
        }

        // If there are query items, add them to the URL.
        if let queryItems, !queryItems.isEmpty {
            var queryStringParts: [String] = []
            for item in queryItems {
                // Don't escape the name (to preserve brackets like 'include[]'), only escape the value.
                let name = item.name
                let value = item.value?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                queryStringParts.append("\(name)=\(value)")
            }
            let queryString = queryStringParts.joined(separator: "&")
            urlComponents.query = queryString
        }

        guard let url = urlComponents.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = httpMethod

        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // If there is a body to encode and the HTTP method supports a body, encode it as JSON.
        if let body, ["POST", "PUT", "PATCH"].contains(httpMethod) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        return request
    }

    /// Parses the data as ErrorResponse, or if it cannot be parsed returns the HTTP status code as otherError
    func errorFromResponse(data: Data, response: HTTPURLResponse) -> Error {
        do {
            let errorResponse = try decoder.decode(ErrorResponse.self, from: data)

            if errorResponse.error.code == "invalid_api_key" || response.statusCode == 401 {
                return APIError.authenticationError(errorResponse.error.message)
            }

            switch errorResponse.error.type {
                case "server_error":
                    return APIError.serverError(errorResponse.error.message)

                case "invalid_request_error":
                    return APIError.invalidRequest(errorResponse.error.message)

                case "insufficient_quota":
                    return APIError.quotaError(errorResponse.error.message)

                case "api_error":
                    return APIError.apiError(errorResponse.error.message)

                default:
                    return APIError.otherError(errorResponse.error.type, errorResponse.error.message)
            }
        } catch {
            let string = String(data: data, encoding: .utf8) ?? ""
            return APIError.otherError("\(response.statusCode)", string)
        }
    }

    /**
     - Parameters:
     - data: The raw response data from the API.
     - response: The HTTP URL response associated with the request.

     - Returns: An instance of type `C`, decoded from the response data.

     - Throws:
     - APIError.invalidResponse: If the response is not a valid HTTPURLResponse.
     - Any errors that occur during decoding of the response data into an instance of type `C`.

     - Note: This function assumes that the API returns a JSON payload, and uses the provided decoder to decode it into an instance of type `C`. The type parameter `C` must conform to the `Codable` protocol.

     */
    func process<C: Codable>(data: Data, response: URLResponse) throws -> C {
        guard let response = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        rateLimit = RateLimit(response: response)

        if response.statusCode == 200 {
            do {
                return try decoder.decode(C.self, from: data)
            } catch {
                throw error
            }
        } else {
            throw errorFromResponse(data: data, response: response)
        }
    }

    func process(data: Data, response: URLResponse) throws -> Data {
        guard let response = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        rateLimit = RateLimit(response: response)

        if response.statusCode == 200 {
            return data
        } else {
            throw errorFromResponse(data: data, response: response)
        }
    }

    /**
     Processes an asynchronous byte stream from a URLSession and returns a `ChatCompletionResponse`.

     - Parameters:
     - asyncBytes: The asynchronous byte stream from the URLSession.
     - response: The HTTP URL response associated with the request.

     - Returns: A `ChatCompletionResponse` object parsed from the asynchronous byte stream.

     - Throws: An error if the response is invalid (non-200 status code), or if there's an issue parsing the JSON data.

     - Note: This function assumes that the API call returns a continuous stream of JSON strings, each representing a `Chunk` object. The function aggregates these `Chunk` objects into a single `ChatCompletionResponse`.

     */
    fileprivate func process(
        asyncBytes: URLSession.AsyncBytes,
        response: URLResponse
    ) async throws -> ChatCompletionResponse {
        guard let response = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        rateLimit = RateLimit(response: response)

        guard response.statusCode == 200 else {
            // read until end
            let data = try await asyncBytes.reduce(into: Data()) { partialResult, byte in
                partialResult.append(byte)
            }

            throw errorFromResponse(data: data, response: response)
        }

        var chatReponse: ChatCompletionResponse!

        var choiceToolCalls = [Int: [Int: ToolCallDelta]]()

        for try await line in asyncBytes.lines {
            guard let range = line.range(of: "data: ") else {
                throw APIError.apiError("Didn't get data at beginning of line")
            }

            let jsonString = line[range.upperBound...]

            if jsonString == "[DONE]" {
                break
            }

            let jsonData = jsonString.data(using: .utf8)!

            let assembler = ChatCompletionAssembler()

            do {
                let chunk = try decoder.decode(Chunk.self, from: jsonData)
                assembler.processChunk(chunk)

                streamingChunkHandler(chunk)

                if chatReponse == nil {
                    let choices = chunk.choices.map { chunkChoice in
                        let message = ChatMessage(
                            role: chunkChoice.delta.role ?? .assistant,
                            content: chunkChoice.delta.content.map { .text($0) }
                        )
                        return ChatCompletionResponse.Choice(
                            message: message,
                            finishReason: chunkChoice.finishReason,
                            index: chunkChoice.index
                        )
                    }

                    chatReponse = ChatCompletionResponse(
                        id: chunk.id,
                        object: "chat.completion",
                        created: chunk.created,
                        model: chunk.model,
                        usage: nil,
                        choices: choices
                    )
                } else {
                    let updatedChoices = chatReponse.choices.map { choice in
                        guard let chunkChoice = chunk.choices.first(where: { $0.index == choice.index }) else {
                            // no matching chunk choice, return unchanged
                            return choice
                        }

                        var message = choice.message

                        let delta = chunkChoice.delta

                        if let deltaMsg = delta.content {
                            let existing = message.textContent ?? ""
                            message.content = .text(existing + deltaMsg)
                        }

                        return ChatCompletionResponse.Choice(
                            message: message,
                            finishReason: choice.finishReason ?? chunkChoice.finishReason,
                            index: choice.index
                        )
                    }

                    chatReponse.choices = updatedChoices
                }

                // update tools for all choices

                for choice in chunk.choices {
                    var choiceCalls = choiceToolCalls[choice.index] ?? [:]

                    for tool in choice.delta.toolCalls ?? [] {
                        guard let toolIndex = tool.index else {
                            continue
                        }

                        if var priorTool = choiceCalls[toolIndex] {
                            // update priorTool where there are values

                            if let id = tool.id {
                                priorTool.id = priorTool.id ?? "" + id
                            }

                            if let newFunction = tool.function {
                                if var priorFunction = priorTool.function {
                                    if let arguments = newFunction.arguments {
                                        priorFunction.arguments = (priorFunction.arguments ?? "") + arguments
                                    }

                                    priorTool.function = priorFunction

                                } else {
                                    priorTool.function = tool.function
                                }
                            }

                            choiceCalls[toolIndex] = priorTool
                        } else {
                            choiceCalls[toolIndex] = tool
                        }
                    }

                    choiceToolCalls[choice.index] = choiceCalls
                }

            } catch {
                print(error)
            }
        }

        let updatedChoices: [ChatCompletionResponse.Choice] = chatReponse.choices.map { oldChoice in
            let choiceCalls = choiceToolCalls[oldChoice.index] ?? [:]

            let sortedToolCalls = choiceCalls.values.sorted { ($0.index ?? Int.max) < ($1.index ?? Int.max) }

            let toolCalls = sortedToolCalls.compactMap { toolCallDelta in
                if let id = toolCallDelta.id,
                    let type = toolCallDelta.type,
                    let function = toolCallDelta.function,
                    let name = function.name,
                    let arguments = function.arguments {
                    let newFunction = FunctionCall(name: name, arguments: arguments)
                    return ToolCall(id: id, type: type, function: newFunction)
                }

                return nil
            }

            var updatedMessage = oldChoice.message

            if toolCalls.isEmpty {
                updatedMessage.toolCalls = nil
            } else {
                updatedMessage.toolCalls = toolCalls
            }

            return ChatCompletionResponse.Choice(
                message: updatedMessage,
                finishReason: oldChoice.finishReason,
                index: oldChoice.index
            )
        }

        chatReponse.choices = updatedChoices

        return chatReponse
    }

    /**
     Processes an asynchronous byte stream from a URLSession and returns a `ChatCompletionResponse`.

     - Parameters:
     - asyncBytes: The asynchronous byte stream from the URLSession.
     - response: The HTTP URL response associated with the request.

     - Returns: A `ChatCompletionResponse` object parsed from the asynchronous byte stream.

     - Throws: An error if the response is invalid (non-200 status code), or if there's an issue parsing the JSON data.

     - Note: This function assumes that the API call returns a continuous stream of JSON strings, each representing a `Chunk` object. The function aggregates these `Chunk` objects into a single `ChatCompletionResponse`.

     */
    func processStream(
        asyncBytes: URLSession.AsyncBytes,
        response: URLResponse
    ) async throws -> AsyncThrowingStream<Chunk, Error> {
        guard let response = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        rateLimit = RateLimit(response: response)

        guard response.statusCode == 200 else {
            // read until end
            let data = try await asyncBytes.reduce(into: Data()) { partialResult, byte in
                partialResult.append(byte)
            }

            throw errorFromResponse(data: data, response: response)
        }

        return AsyncThrowingStream { continuation in
            Task {

                for try await line in asyncBytes.lines {
                    // print(line)

                    guard let range = line.range(of: "data: ") else {
                        throw APIError.apiError("Didn't get data at beginning of line")
                    }

                    let jsonString = line[range.upperBound...]

                    if jsonString == "[DONE]" {
                        continuation.finish()
                        return
                    }

                    let jsonData = jsonString.data(using: .utf8)!

                    do {
                        let chunk = try self.decoder.decode(Chunk.self, from: jsonData)
                        continuation.yield(chunk)
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }
}
