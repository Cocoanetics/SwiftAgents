//
//  OpenAI.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 19.04.24.
//

import Foundation
import SwiftCross
import SwiftMCP

open class OpenAI: API, @unchecked Sendable {
    /// OpenAI Responses API: stateful, ids routable to OpenAI tracing.
    override open var statePolicy: ConversationStatePolicy { .openAIResponses }

    /// Whether the streamed `Runner` loop should use the Responses streaming API
    /// (`/v1/responses`) for this client. Defaults to the first-party endpoint;
    /// custom Responses backends (e.g. the ChatGPT/Codex backend) override this
    /// to `true`. OpenAI-compatible chat-only endpoints leave it `false` so they
    /// keep streaming via `/v1/chat/completions`.
    open var prefersResponsesStreaming: Bool { endpointURL == .openAI }

    /// Initializes OpenAI API. If now API key is provided, then we're looking for OPENAI_API_KEY in the environment
    override public init(
        credential: (any RequestAuthorizing)? = nil,
        endpointURL: URL = .openAI,
        versionPath: String = "v1"
    ) {
        super.init(
            credential: credential ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"].map(Credential.bearer),
            endpointURL: endpointURL,
            versionPath: versionPath
        )
        // Auto-register an `OpenAITraceExporter` against the global
        // `TraceProvider` the first time any OpenAI client is created with
        // `OPENAI_API_KEY` in the environment. See `OpenAITracingAutoConfig`.
        OpenAITracingAutoConfig.configureIfNeeded()
    }

    // MARK: - Embeddings

    /// When generating embeddings via the OpenAI API this is the embedding model to use
    public var embeddingModelIdentifier: String = "text-embedding-3-small"

    public func embedding(input: String, model: String) async throws -> [EmbeddingVector] {
        let embeddingRequest = EmbeddingRequest(input: input, model: model)
        let request = try createUrlRequest(
            httpMethod: "POST",
            path: "/\(versionPath)/embeddings",
            body: embeddingRequest
        )

        let (data, response) = try await session.data(for: request)
        let embeddingResponse: EmbeddingResponse = try process(data: data, response: response)
        return embeddingResponse.data
    }

    // MARK: - Helpers

    override public func createChatCompletion(
        model: String,
        messages: [ChatMessage],
        tools: [ToolDescription]? = nil,
        toolChoice: ToolChoice? = nil,
        n: Int? = nil,
        stop: [String]? = nil,
        store: Bool? = nil,
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
            store: store,
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

    override public func createChatCompletionStream(
        model: String,
        messages: [ChatMessage],
        tools: [ToolDescription]? = nil,
        toolChoice: ToolChoice? = nil,
        n: Int = 1,
        streamOptions: ChatCompletionRequest.StreamOptions? = nil,
        stop: [String]? = nil,
        store: Bool? = nil,
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
            store: store,
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

    override open func createUrlRequest(
        httpMethod: String = "GET",
        path: String,
        body: Codable? = nil,
        queryItems: [URLQueryItem]? = nil
    ) throws -> URLRequest {
        // get standard request from API
        var request = try super.createUrlRequest(httpMethod: httpMethod, path: path, body: body, queryItems: queryItems)

        // add header to enable Assistants v2 (not for Conversations/Responses API endpoints)
        if !path.contains("/conversations") {
            request.setValue("assistants=v2", forHTTPHeaderField: "OpenAI-Beta")
        }

        return request
    }

    // MARK: - ServerHistoryAPI

    /// Dispatch a single stateful Responses turn. The `ServerHistoryAPI`
    /// conformance is declared in `ServerHistoryAPI.swift`, but the witness
    /// lives here on the class body — not in that extension — so subclasses can
    /// `override` it. (Methods declared in extensions are statically dispatched
    /// and cannot be overridden; `OpenAIResponsesWebSocket` routes this turn
    /// over a WebSocket by overriding exactly this method.)
    package func dispatchCreateResponse(
        input: Response.Input,
        model: String,
        instructions: String?,
        previousResponseId: String?,
        conversationId: String?,
        textFormat: TextFormat?,
        tools: [Tool]?,
        modelSettings: ModelSettings
    ) async throws -> Response {
        try await createResponse(
            input: input,
            model: model,
            conversation: conversationId,
            instructions: instructions,
            maxOutputTokens: modelSettings.maxCompletionTokens,
            metadata: modelSettings.metadata,
            parallelToolCalls: modelSettings.parallelToolCalls,
            previousResponseId: previousResponseId,
            reasoning: modelSettings.reasoning,
            store: modelSettings.store,
            temperature: modelSettings.temperature,
            textFormat: textFormat,
            toolChoice: modelSettings.toolChoice,
            tools: tools,
            topP: modelSettings.topP,
            truncation: modelSettings.truncation
        )
    }

    /// Fetches an ephemeral OpenAI API key from a backend mint endpoint. Mobile
    /// and other client apps should mint short-lived tokens server-side rather
    /// than embedding a long-lived key in the bundle (per OpenAI's guidance).
    ///
    /// The endpoint may return the token either as raw text in the response
    /// body, or as a JSON object containing one of `client_secret.value`,
    /// `value`, or `token` — covering the common backend shapes.
    public static func fetchEphemeralAPIKey(
        from url: URL,
        urlSession: URLSession = .shared
    ) async throws -> String {
        let (data, response) = try await urlSession.data(from: url)

        if let httpResponse = response as? HTTPURLResponse,
           !(200 ..< 300).contains(httpResponse.statusCode) {
            throw APIError.serverError("Token endpoint returned HTTP \(httpResponse.statusCode)")
        }

        if let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           !raw.hasPrefix("{") {
            return raw
        }

        let payload = try JSONDecoder().decode(JSONValue.self, from: data)
        let nested = payload["client_secret"]?["value"]?.stringValue
        let flat = payload["value"]?.stringValue ?? payload["token"]?.stringValue
        if let token = nested ?? flat {
            return token
        }

        throw APIError.invalidRequest("Token endpoint payload missing client_secret/value/token field.")
    }
}
