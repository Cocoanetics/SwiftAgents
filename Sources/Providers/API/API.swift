//
// 	API.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 08.05.23.
//

import Foundation
import Tracing
import SwiftCross

public extension URL {
    /// Default endpoint URL for the OpenAI Chat endpoint
    static let openAI = URL(string: "https://api.openai.com")!

    /// Default endpoint URL for the Google AI API endpoint
    static let googleAI = URL(string: "https://generativelanguage.googleapis.com")!
}

open class API: @unchecked Sendable {
    package let endpointURL: URL
    let session: URLSession

    /// Session for the SSE streaming endpoints. Kept separate from `session`
    /// because that one caps the *total* response load at 360 s
    /// (`timeoutIntervalForResource`), which would hard-kill long generations
    /// mid-stream. Both timeouts here are 600 s, matching the dedicated
    /// stream sessions the Responses and Anthropic paths use.
    let streamSession: URLSession

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

    /// Authorizes outgoing requests. Providers set this from their initializer
    /// (an API key becomes the matching ``Credential``); it stays settable so a
    /// caller can swap in OAuth or other credentials afterward.
    public var credential: (any RequestAuthorizing)?

    // MARK: - Initialization

    public init(credential: (any RequestAuthorizing)? = nil, endpointURL: URL = .openAI, versionPath: String = "v1") {
        self.credential = credential
        self.endpointURL = endpointURL
        self.versionPath = versionPath

        // Create a URLSessionConfiguration
        let configuration = URLSessionConfiguration.default
        // Set the timeout interval for the request (in seconds)
        configuration.timeoutIntervalForRequest = 360 // For example, 30 seconds
        configuration.timeoutIntervalForResource = 360

        // Create a URLSession with the configuration
        session = URLSession(configuration: configuration)

        // Streaming needs a generous *resource* timeout: the request timeout
        // only bounds idle time between bytes, but the resource timeout caps
        // the whole transfer — a long generation would be cut off mid-stream
        // by the 360 s above.
        let streamConfiguration = URLSessionConfiguration.default
        streamConfiguration.timeoutIntervalForRequest = 600
        streamConfiguration.timeoutIntervalForResource = 600
        streamSession = URLSession(configuration: streamConfiguration)
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
        user: String? = nil,
        options _: GenerationOptions? = nil
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

        let (data, response) = try await session.data(for: request)

        return try process(data: data, response: response)
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

        let (asyncBytes, response) = try await streamSession.bytes(for: request)
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

        // All auth flows through the credential. Providers that build requests
        // without the base builder (Anthropic, the OAuth subclasses) apply it in
        // their own `createUrlRequest`.
        credential?.authorize(&request)

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

            // A 401 always reads as authentication, regardless of how the body
            // labels itself.
            if response.statusCode == 401 {
                return APIError.authenticationError(errorResponse.error.message)
            }

            return apiError(from: errorResponse.error)
        } catch {
            let string = String(data: data, encoding: .utf8) ?? ""
            return APIError.otherError("\(response.statusCode)", string)
        }
    }

    /// Maps a single `ErrorDetail` to the project error model.
    ///
    /// Shared by `errorFromResponse` (HTTP bodies) and the Responses WebSocket
    /// transport (`error` frames and `response.failed` payloads), so an error
    /// reads the same regardless of channel. Crucially it inspects `code` /
    /// `param` / `message`, not just `type` — both `previous_response_not_found`
    /// and `websocket_connection_limit_reached` are `invalid_request_error`s
    /// that a type-only switch would flatten into `.invalidRequest`, losing the
    /// signal the recovery logic depends on.
    func apiError(from detail: ErrorDetail) -> Error {
        if detail.code == "invalid_api_key" {
            return APIError.authenticationError(detail.message)
        }

        if detail.code == "previous_response_not_found" {
            return APIError.previousResponseNotFound(param: detail.param)
        }

        let lowerMessage = detail.message.lowercased()
        if detail.code == "websocket_connection_limit_reached" || lowerMessage.contains("connection limit") {
            return APIError.connectionLimitReached
        }

        switch detail.type {
            case "server_error":
                return APIError.serverError(detail.message)

            case "invalid_request_error":
                return APIError.invalidRequest(detail.message)

            case "insufficient_quota":
                return APIError.quotaError(detail.message)

            case "api_error":
                return APIError.apiError(detail.message)

            default:
                return APIError.otherError(detail.type, detail.message)
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
            return try decoder.decode(C.self, from: data)
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
     Turns the SSE byte stream of a streaming chat-completion request into a
     stream of `Chunk`s.

     - Parameters:
     - asyncBytes: The asynchronous byte stream from the URLSession.
     - response: The HTTP URL response associated with the request.

     - Returns: An `AsyncThrowingStream` of `Chunk` objects, finishing when the
     server sends the `[DONE]` sentinel or closes the stream.

     - Throws: An error if the response is invalid (non-200 status code); the
     returned stream itself throws on transport or decoding failures.

     */
    func processStream(
        asyncBytes: URLSession.AsyncBytes,
        response: URLResponse
    ) async throws -> AsyncThrowingStream<Chunk, Error> {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        rateLimit = RateLimit(response: httpResponse)

        try await throwIfStreamError(response: response, asyncBytes: asyncBytes, mapError: errorFromResponse)

        return chunkStream(from: asyncBytes)
    }

    /// Decodes SSE data payloads into chat-completion `Chunk`s. Framing runs
    /// through the shared spec-correct `SSEDataSequence` (comments and blank
    /// lines that proxies like OpenRouter or LiteLLM interleave are tolerated).
    /// Generic over the byte source so the framing is testable offline.
    func chunkStream<Bytes: AsyncSequence & Sendable>(
        from bytes: Bytes
    ) -> AsyncThrowingStream<Chunk, Error> where Bytes.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await payload in SSEDataSequence(bytes: bytes) {
                        if payload == SSE.doneSentinel {
                            break
                        }

                        continuation.yield(try self.decoder.decode(Chunk.self, from: payload))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
