//
//  Anthropic.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.05.26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftMCP

public extension URL {
    /// Default endpoint URL for the Anthropic Messages API.
    static let anthropic = URL(string: "https://api.anthropic.com")!
}

/// Anthropic Messages API client.
///
/// Talks to `POST /v1/messages` with `x-api-key` + `anthropic-version` headers
/// (no `Authorization: Bearer …`). Native request/response shapes are mapped
/// onto SwiftAgents' OpenAI-shaped `ChatCompletionResponse` and `Response`
/// types so the same Agents/Runner code paths work across providers.
///
/// See: https://platform.claude.com/docs/en/api/messages
public class Anthropic: API, @unchecked Sendable {
    /// Anthropic Messages API version. The 2023-06-01 release is the
    /// long-lived stable version — newer dated revisions are opt-in.
    public static let defaultAnthropicVersion = "2023-06-01"

    /// `anthropic-version` header value sent with every request.
    public let anthropicVersion: String

    /// Default `max_tokens` used when the caller doesn't supply one. The
    /// Anthropic API requires `max_tokens`; the Responses API does not, so
    /// we fall back to this value to bridge that gap.
    public var defaultMaxTokens: Int = 4096

    /// JSON encoder for Anthropic wire types. We don't use the inherited
    /// `API.encoder` because that decoder applies a snake_case ↔ camelCase
    /// strategy that fights the explicit `CodingKeys` on our types (and
    /// special-cases `tools` / `schema` containers in ways that don't match
    /// Anthropic's wire format).
    public let anthropicEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// JSON decoder for Anthropic wire types. See `anthropicEncoder` for
    /// rationale.
    public let anthropicDecoder: JSONDecoder = JSONDecoder()

    /// Cache of full Anthropic conversation histories keyed by the response
    /// id that closed each turn. Lets us synthesise the equivalent of OpenAI's
    /// `previousResponseId` against Anthropic's stateless Messages API — see
    /// `AnthropicConversationCache` for the bridge.
    public let conversationCache = AnthropicConversationCache()

    public init(
        apiKey: String? = nil,
        endpointURL: URL = .anthropic,
        anthropicVersion: String = Anthropic.defaultAnthropicVersion
    ) {
        self.anthropicVersion = anthropicVersion
        super.init(
            apiKey: apiKey ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
            endpointURL: endpointURL,
            versionPath: "v1"
        )
    }

    /// Anthropic doesn't use the OpenAI `Authorization: Bearer` header — it
    /// uses `x-api-key` plus an `anthropic-version` header that pins the
    /// wire-protocol revision.
    override open func createUrlRequest(
        httpMethod: String = "GET",
        path: String,
        body: Codable? = nil,
        queryItems: [URLQueryItem]? = nil
    ) throws -> URLRequest {
        guard var urlComponents = URLComponents(
            url: endpointURL.appending(path: path),
            resolvingAgainstBaseURL: true
        ) else {
            throw URLError(.badURL)
        }

        if let queryItems, !queryItems.isEmpty {
            urlComponents.queryItems = queryItems
        }

        guard let url = urlComponents.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = httpMethod

        if let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")

        if let body, ["POST", "PUT", "PATCH"].contains(httpMethod) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try anthropicEncoder.encode(body)
        }

        return request
    }

    /// Cross-provider Chat Completions surface. Converts OpenAI-shaped
    /// arguments into an `AnthropicMessagesRequest`, calls Anthropic, and
    /// folds the response back into the OpenAI-shaped
    /// `ChatCompletionResponse` so existing chat-completion code paths work
    /// unchanged.
    override public func createChatCompletion(
        model: String,
        messages: [ChatMessage],
        tools: [ToolDescription]? = nil,
        toolChoice: ToolChoice? = nil,
        n _: Int? = nil,
        stop: [String]? = nil,
        store _: Bool? = nil,
        temperature: Double? = nil,
        maxCompletionTokens: Int? = nil,
        metadata _: [String: String]? = nil,
        parallelToolCalls _: Bool? = nil,
        presencePenalty _: Double? = nil,
        responseFormat _: ChatCompletionRequest.ResponseFormat? = nil,
        frequencyPenalty _: Double? = nil,
        logitBias _: [String: Int]? = nil,
        user: String? = nil
    ) async throws -> ChatCompletionResponse {
        let (system, anthropicMessages) = Anthropic.convertChatMessages(messages)

        let request = AnthropicMessagesRequest(
            model: model,
            messages: anthropicMessages,
            maxTokens: maxCompletionTokens ?? defaultMaxTokens,
            system: system,
            temperature: temperature,
            topP: nil,
            topK: nil,
            stopSequences: stop,
            stream: false,
            tools: Anthropic.convertToolDescriptions(tools),
            toolChoice: Anthropic.convertToolChoice(toolChoice),
            metadata: user.map { AnthropicMessagesRequest.Metadata(userId: $0) }
        )

        let anthropicResponse = try await createMessage(request)
        return Anthropic.makeChatCompletionResponse(model: model, response: anthropicResponse)
    }

    /// Streaming chat completions are not implemented for the chat-completion
    /// surface — agents-SDK consumers should use `createResponseStream`
    /// instead, which goes through the Anthropic Messages streaming endpoint.
    override public func createChatCompletionStream(
        model _: String,
        messages _: [ChatMessage],
        tools _: [ToolDescription]? = nil,
        toolChoice _: ToolChoice? = nil,
        n _: Int = 1,
        streamOptions _: ChatCompletionRequest.StreamOptions? = nil,
        stop _: [String]? = nil,
        store _: Bool? = nil,
        temperature _: Double? = nil,
        maxCompletionTokens _: Int? = nil,
        metadata _: [String: String]? = nil,
        parallelToolCalls _: Bool? = nil,
        presencePenalty _: Double = 0.0,
        responseFormat _: ChatCompletionRequest.ResponseFormat? = nil,
        frequencyPenalty _: Double = 0.0,
        logitBias _: [String: Int]? = nil,
        user _: String? = nil
    ) async throws -> AsyncThrowingStream<Chunk, Error> {
        throw APIError.otherError(
            "unsupported",
            "Anthropic chat-completion streaming is not implemented — use createResponseStream."
        )
    }

    /// Calls `POST /v1/messages` and returns the parsed native response.
    ///
    /// Most callers should go through `createChatCompletion` /
    /// `createResponse` for cross-provider compatibility; this method is
    /// exposed so consumers who want Anthropic-specific features
    /// (cache_control, thinking blocks, etc.) can use the native types
    /// directly.
    public func createMessage(_ request: AnthropicMessagesRequest) async throws -> AnthropicMessagesResponse {
        let urlRequest = try createUrlRequest(httpMethod: "POST", path: "/v1/messages", body: request)
        let (data, response) = try await session.data(for: urlRequest)
        return try processAnthropicResponse(data: data, response: response)
    }

    /// Calls `POST /v1/messages` with `stream: true` and returns an async
    /// sequence of parsed SSE events.
    public func createMessageStream(
        _ request: AnthropicMessagesRequest
    ) async throws -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        var streamingRequest = request
        if request.stream != true {
            streamingRequest = AnthropicMessagesRequest(
                model: request.model,
                messages: request.messages,
                maxTokens: request.maxTokens,
                system: request.system,
                temperature: request.temperature,
                topP: request.topP,
                topK: request.topK,
                stopSequences: request.stopSequences,
                stream: true,
                tools: request.tools,
                toolChoice: request.toolChoice,
                metadata: request.metadata
            )
        }
        let urlRequest = try createUrlRequest(httpMethod: "POST", path: "/v1/messages", body: streamingRequest)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 600
        let streamSession = URLSession(configuration: config)

        let (asyncBytes, response) = try await streamSession.bytes(for: urlRequest)
        return try await processAnthropicStream(asyncBytes: asyncBytes, response: response)
    }

    // MARK: - Internal Helpers

    /// Decodes `AnthropicMessagesResponse` from a 200 response, or throws an
    /// `APIError` derived from the Anthropic error payload otherwise.
    func processAnthropicResponse(data: Data, response: URLResponse) throws -> AnthropicMessagesResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if httpResponse.statusCode == 200 {
            return try anthropicDecoder.decode(AnthropicMessagesResponse.self, from: data)
        }
        throw anthropicError(from: data, response: httpResponse)
    }

    /// Builds an `APIError` from an Anthropic error response body. Falls back
    /// to a generic `otherError` if the payload doesn't match the expected
    /// shape.
    func anthropicError(from data: Data, response: HTTPURLResponse) -> Error {
        if let errorResponse = try? anthropicDecoder.decode(AnthropicErrorResponse.self, from: data) {
            let message = errorResponse.error.message
            switch errorResponse.error.type {
                case "authentication_error":
                    return APIError.authenticationError(message)
                case "invalid_request_error":
                    return APIError.invalidRequest(message)
                case "rate_limit_error", "overloaded_error":
                    return APIError.quotaError(message)
                case "api_error":
                    return APIError.apiError(message)
                default:
                    return APIError.otherError(errorResponse.error.type, message)
            }
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        return APIError.otherError("\(response.statusCode)", body)
    }
}
