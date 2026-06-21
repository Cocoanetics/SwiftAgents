//
//  OpenAIResponsesWebSocket.swift
//  SwiftAgents
//
//  A drop-in `OpenAI` whose stateful turns travel over a persistent WebSocket
//  instead of a fresh HTTPS request each turn. It inherits everything from
//  `OpenAI` — including `statePolicy == .openAIResponses`, so the Runner's
//  stateful path picks it up with no loop changes — and overrides just
//  `dispatchCreateResponse` to route the turn through an
//  `OpenAIResponsesWebSocketModel`.
//
//  Usage (per session — recommended, since a socket is sequential and
//  session-scoped):
//
//      let ws = OpenAIResponsesWebSocket()
//      try await ws.warmup(model: "gpt-5.1", instructions: agent.instructions, tools: tools)
//      let result = try await Runner.run(agent, input: "…", config: RunConfig(api: ws))
//      await ws.disconnect()
//
//  Parallel runs each want their own instance: one connection carries one turn
//  at a time, so share an instance only across sequential turns.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class OpenAIResponsesWebSocket: OpenAI, @unchecked Sendable {
    private let transport: OpenAIResponsesWebSocketModel

    /// - Parameters:
    ///   - credential: OpenAI credential. Falls back to `OPENAI_API_KEY` when nil.
    ///   - endpointURL: API base. The handshake rewrites `https`→`wss` and
    ///     targets `/<versionPath>/responses`.
    ///   - maxConnectionAge: reconnect proactively once a connection reaches
    ///     this age, staying ahead of the server's 60-minute cap.
    ///   - session: optional injected `URLSession` (long timeouts by default).
    ///   - connectionFactory: optional socket factory — tests inject a mock to
    ///     run the whole transport offline.
    public init(
        credential: (any RequestAuthorizing)? = nil,
        endpointURL: URL = .openAI,
        versionPath: String = "v1",
        maxConnectionAge: TimeInterval = 55 * 60,
        session: URLSession? = nil,
        connectionFactory: ResponsesWebSocketConnectionFactory? = nil
    ) {
        // A dedicated backing `OpenAI` gives the transport its encoder/decoder
        // and endpoint without retaining `self` (which would cycle through the
        // actor). It resolves the same key/endpoint, so the wire bytes match.
        let backing = OpenAI(credential: credential, endpointURL: endpointURL, versionPath: versionPath)
        transport = OpenAIResponsesWebSocketModel(
            openAI: backing,
            maxConnectionAge: maxConnectionAge,
            session: session,
            connectionFactory: connectionFactory
        )
        super.init(credential: credential, endpointURL: endpointURL, versionPath: versionPath)
    }

    // MARK: - Lifecycle

    /// Open the socket ahead of the first turn (optional; turns connect lazily).
    public func connect() async throws {
        try await transport.connect()
    }

    /// Close the socket and fail any in-flight turn.
    public func disconnect() async {
        await transport.disconnect()
    }

    /// The most recent completed/warmed response id on the live connection, or
    /// `nil` if none yet (or it was evicted by a failed turn). Handy to seed a
    /// chain after `warmup`.
    public func lastResponseId() async -> String? {
        await transport.lastResponseId
    }

    // MARK: - Warmup

    /// Pre-stage tools / instructions / input on the connection with a
    /// `generate:false` turn, shaving latency off the first real turn. Returns
    /// the warmup `Response`; its `id` (also available via `lastResponseId()`)
    /// is a chainable base for the next turn.
    @discardableResult
    public func warmup(
        model: String,
        instructions: String? = nil,
        tools: [Tool]? = nil,
        input: Response.Input = .array([]),
        previousResponseId: String? = nil,
        modelSettings: ModelSettings = ModelSettings()
    ) async throws -> Response {
        let event = ResponsesCreateEvent(
            input: input,
            model: model,
            generate: false,
            instructions: instructions,
            maxOutputTokens: modelSettings.maxCompletionTokens,
            metadata: modelSettings.metadata,
            parallelToolCalls: modelSettings.parallelToolCalls,
            previousResponseId: previousResponseId,
            reasoning: modelSettings.reasoning,
            store: modelSettings.store,
            temperature: modelSettings.temperature,
            toolChoice: modelSettings.toolChoice,
            tools: tools,
            topP: modelSettings.topP,
            truncation: modelSettings.truncation
        )
        return try await transport.send(event)
    }

    // MARK: - Streaming (over the socket)

    /// Stream one turn's events over the socket, mirroring the parameter set the
    /// streaming run loop passes to the HTTP `createResponseStream`. Yields every
    /// `ResponsesStreamEvent` (deltas included) and finishes on the terminal
    /// event. `package` so the Agents `runStreamed` loop can drive it.
    package func streamResponse(
        input: Response.Input,
        model modelID: String,
        instructions: String?,
        previousResponseId: String?,
        tools: [Tool]?,
        modelSettings: ModelSettings
    ) -> AsyncThrowingStream<ResponsesStreamEvent, Error> {
        let event = ResponsesCreateEvent(
            input: input,
            model: modelID,
            instructions: instructions,
            maxOutputTokens: modelSettings.maxCompletionTokens,
            metadata: modelSettings.metadata,
            parallelToolCalls: modelSettings.parallelToolCalls,
            previousResponseId: previousResponseId,
            reasoning: modelSettings.reasoning,
            store: modelSettings.store,
            temperature: modelSettings.temperature,
            toolChoice: modelSettings.toolChoice,
            tools: tools,
            topP: modelSettings.topP,
            truncation: modelSettings.truncation
        )
        return transport.streamResponse(event)
    }

    // MARK: - ServerHistoryAPI (over the socket)

    override package func dispatchCreateResponse(
        input: Response.Input,
        model modelID: String,
        instructions: String?,
        previousResponseId: String?,
        conversationId: String?,
        textFormat: TextFormat?,
        tools: [Tool]?,
        modelSettings: ModelSettings
    ) async throws -> Response {
        let text: TextConfiguration? = textFormat.map { TextConfiguration(format: $0) }

        let event = ResponsesCreateEvent(
            input: input,
            model: modelID,
            conversation: conversationId,
            instructions: instructions,
            maxOutputTokens: modelSettings.maxCompletionTokens,
            metadata: modelSettings.metadata,
            parallelToolCalls: modelSettings.parallelToolCalls,
            previousResponseId: previousResponseId,
            reasoning: modelSettings.reasoning,
            store: modelSettings.store,
            temperature: modelSettings.temperature,
            text: text,
            toolChoice: modelSettings.toolChoice,
            tools: tools,
            topP: modelSettings.topP,
            truncation: modelSettings.truncation
        )

        return try await transport.send(event)
    }
}
