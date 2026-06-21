//
//  OpenAIResponsesWebSocketModel.swift
//  SwiftAgents
//
//  Persistent-connection transport for the OpenAI Responses API
//  (`wss://api.openai.com/v1/responses`). Structurally a sibling of
//  `OpenAIRealtimeWebSocketModel`: a `public actor` wrapping one socket with a
//  connect / receive-loop / send / disconnect lifecycle, decoding inbound
//  frames through the *same* event mapping the SSE path uses.
//
//  Two things make it more than a copy:
//
//  1. It is **request-scoped**, not stream-scoped. The agent loop wants one
//     assembled `Response` per turn, so `send(_:)` sends a `response.create`
//     and suspends until that turn's terminal event, returning the `Response`.
//     One turn is in flight at a time — the connection has no multiplexing.
//
//  2. It owns the connection-level concerns the HTTP path never had: a
//     connection-local `lastResponseId` cache, eviction on failure, a
//     proactive reconnect before the server's 60-minute cap, and a reconnect +
//     resend on a dropped socket or `websocket_connection_limit_reached`.
//
//  The socket is reached through `ResponsesWebSocketConnection`, so tests drive
//  the whole actor offline with a scripted mock — no network, no API key. The
//  connection is never passed across an isolation boundary; the receive loop
//  reads it from `self` and uses a monotonic `connectionGeneration` to ignore
//  events from a connection that has since been replaced.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor OpenAIResponsesWebSocketModel {
    private let openAI: OpenAI
    private let session: URLSession
    private let makeConnection: ResponsesWebSocketConnectionFactory

    /// Reconnect proactively once a connection reaches this age, staying ahead
    /// of the server's hard 60-minute cap. Injectable so tests can force it.
    private let maxConnectionAge: TimeInterval

    /// How many times a single turn will reconnect-and-resend on a recoverable
    /// connection loss before giving up.
    private let maxReconnectAttempts: Int

    private var connection: (any ResponsesWebSocketConnection)?
    private var receiveTask: Task<Void, Never>?
    private var connectedAt: Date?

    /// Bumped on every connect and every teardown. The receive loop captures
    /// the generation it was started for and ignores any wake-up once the live
    /// generation has moved on — so a socket replaced mid-flight can't resolve
    /// or fail a turn that belongs to its successor.
    private var connectionGeneration = 0

    /// The continuation for a request-scoped turn (`send(_:)`) awaiting its
    /// terminal event. Resolved exactly once, by whichever of the receive loop
    /// or the send task reaches it first.
    private var inFlight: CheckedContinuation<Response, Error>?

    /// The continuation for a streaming turn (`streamResponse(_:)`). When set,
    /// the receive loop forwards *every* decoded event here and finishes the
    /// stream on the terminal one. The turn gate guarantees `inFlight` and
    /// `streamSink` are never both set.
    private var streamSink: AsyncThrowingStream<ResponsesStreamEvent, Error>.Continuation?

    /// Resumed when a streaming turn reaches its terminal event (or fails), so
    /// `runStream` can stop holding the turn gate. Paired with `streamSink`.
    private var streamCompletion: CheckedContinuation<Void, Error>?

    /// FIFO gate enforcing one in-flight turn at a time (async semaphore of 1).
    private var turnActive = false
    private var turnWaiters: [CheckedContinuation<Void, Never>] = []

    /// Most recent completed/warmed response id on *this* connection. Seeds the
    /// fast-continue path and is what a caller reads after `warmup`. Evicted on
    /// any failed turn.
    public private(set) var lastResponseId: String?

    public init(
        openAI: OpenAI = OpenAI(),
        maxConnectionAge: TimeInterval = 55 * 60,
        maxReconnectAttempts: Int = 2,
        session: URLSession? = nil,
        connectionFactory: ResponsesWebSocketConnectionFactory? = nil
    ) {
        self.openAI = openAI
        self.maxConnectionAge = maxConnectionAge
        self.maxReconnectAttempts = maxReconnectAttempts

        let resolvedSession: URLSession
        if let session {
            resolvedSession = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 600
            configuration.timeoutIntervalForResource = 600
            resolvedSession = URLSession(configuration: configuration)
        }
        self.session = resolvedSession
        makeConnection = connectionFactory ?? { request in resolvedSession.webSocketTask(with: request) }
    }

    // MARK: - Lifecycle

    /// Open the socket if it isn't already up. Optional — `send(_:)` connects
    /// lazily — but lets a caller pay the handshake cost ahead of the first
    /// turn.
    public func connect() throws {
        try ensureConnectedNow()
    }

    /// Close the socket and fail any in-flight turn.
    public func disconnect() {
        teardown()
        failActiveTurn(ResponsesWebSocketError.connectionClosed)
    }

    /// Force the connection-local cache to a known id (e.g. after seeding the
    /// chain from outside). Clearing is allowed.
    public func seedLastResponseId(_ id: String?) {
        lastResponseId = id
    }

    // MARK: - Turns

    /// Send one `response.create` and await the turn's terminal event.
    ///
    /// Connects (or reconnects, if the connection is past its max age) before
    /// sending, serializes against any other turn, and on a recoverable
    /// connection loss reconnects and re-sends the same event. Returns the
    /// `Response` from `response.completed` (or `response.incomplete`); throws
    /// the mapped error from `response.failed` / an `error` frame.
    @discardableResult
    func send(_ event: ResponsesCreateEvent) async throws -> Response {
        await acquireTurn()
        defer { releaseTurn() }

        var attempt = 0
        while true {
            attempt += 1
            do {
                try ensureConnectedNow()
                let response = try await transmitAndAwait(event)
                recordSuccess(response)
                return response
            } catch {
                // Any failed turn drops the cached id (the service evicts it
                // connection-side too).
                lastResponseId = nil

                if attempt <= maxReconnectAttempts, Self.isRecoverableConnectionLoss(error) {
                    teardown()
                    continue
                }
                throw error
            }
        }
    }

    /// Send one `response.create` and surface the turn's events as they arrive.
    ///
    /// Unlike ``send(_:)``, which assembles a single `Response`, this forwards
    /// every decoded ``ResponsesStreamEvent`` — `output_text.delta`,
    /// `output_item.*`, reasoning deltas, and the terminal `completed` /
    /// `failed` / `incomplete` — so a caller can render output token-by-token.
    /// The stream finishes after the terminal event (and throws on `failed` /
    /// an `error` frame).
    ///
    /// A mid-stream connection loss **fails the stream** rather than silently
    /// resending: partial deltas have already been delivered, so a resend would
    /// duplicate them. The caller (the run loop) recovers by reissuing the turn.
    /// Like ``send(_:)`` this holds the single-in-flight turn gate for the whole
    /// turn, so streaming and non-streaming turns never overlap on one socket.
    ///
    /// `nonisolated` because the body only *constructs* the stream and a driver
    /// `Task`; all actor-state access happens inside `drive(_:into:)`.
    nonisolated func streamResponse(
        _ event: ResponsesCreateEvent
    ) -> AsyncThrowingStream<ResponsesStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.drive(event, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Actor-isolated driver for one streaming turn: hold the turn gate, connect,
    /// send, and await the terminal event — finishing the sink with any error.
    private func drive(
        _ event: ResponsesCreateEvent,
        into sink: AsyncThrowingStream<ResponsesStreamEvent, Error>.Continuation
    ) async {
        await acquireTurn()
        defer { releaseTurn() }
        do {
            try ensureConnectedNow()
            try await runStream(event, into: sink)
        } catch {
            // A failed turn drops the cached id (the service evicts it too). The
            // terminal-event path already finished the sink on a clean failure;
            // this covers connect/encode failures before the first event.
            lastResponseId = nil
            sink.finish(throwing: error)
        }
    }

    // MARK: - Connection management

    private func ensureConnectedNow() throws {
        // Proactively cycle the connection before the server's 60-minute cap.
        if let connectedAt, Date().timeIntervalSince(connectedAt) >= maxConnectionAge {
            teardown()
        }

        guard connection == nil else {
            return
        }

        guard let credential = openAI.credential else {
            throw ResponsesWebSocketError.missingAPIKey
        }

        let request = try websocketRequest(credential: credential)
        let connection = makeConnection(request)
        self.connection = connection
        connectedAt = Date()
        connectionGeneration += 1
        let generation = connectionGeneration
        connection.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(generation: generation)
        }
    }

    private func teardown() {
        receiveTask?.cancel()
        receiveTask = nil
        connection?.cancel(with: .normalClosure, reason: nil)
        connection = nil
        connectedAt = nil
        connectionGeneration += 1
    }

    private func receiveLoop(generation: Int) async {
        do {
            while !Task.isCancelled {
                // Reading the connection from `self` (rather than capturing it)
                // keeps the non-Sendable socket inside the actor, and the
                // generation check drops a loop whose connection was replaced.
                guard generation == connectionGeneration, let connection else {
                    return
                }

                let message = try await connection.receive()

                guard generation == connectionGeneration else {
                    return
                }

                let data: Data
                switch message {
                    case let .string(string):
                        data = Data(string.utf8)
                    case let .data(payload):
                        data = payload
                    @unknown default:
                        continue
                }

                do {
                    // Unrecognized event types decode to nil and are skipped,
                    // so a forward-compatible event never tears down the socket.
                    guard let event = try ResponsesStreamEvent(from: data, decoder: openAI.decoder) else {
                        continue
                    }
                    route(event)
                } catch {
                    // A recognized event whose payload is malformed fails the
                    // turn in flight. We must also tear the socket down: the
                    // server keeps streaming the rest of this response, and
                    // because frames aren't correlated to a request id, a stale
                    // terminal frame arriving after the gate is released could
                    // resolve the *next* turn with the wrong response. Dropping
                    // the connection forces the next turn to reconnect clean.
                    if ProcessInfo.processInfo.environment["DEBUG_RESPONSES"] != nil {
                        let payload = String(data: data, encoding: .utf8) ?? "<binary>"
                        NSLog("[DEBUG_RESPONSES] Failed to decode Responses WS frame: %@", payload)
                    }
                    teardown()
                    failActiveTurn(error)
                    return
                }
            }
        } catch is CancellationError {
            // Expected on teardown.
        } catch {
            // Socket dropped. Only react if this is still the live generation —
            // otherwise a successor connection has already taken over and owns
            // any in-flight turn.
            guard generation == connectionGeneration else {
                return
            }
            // Close and clear the dead socket here (rather than leaving it for
            // the next `teardown`) so cleanup is symmetric with the
            // error-frame path and a later `disconnect` can't double-handle it.
            connection?.cancel(with: .abnormalClosure, reason: nil)
            connection = nil
            connectedAt = nil
            connectionGeneration += 1
            failActiveTurn(ResponsesWebSocketError.connectionClosed)
        }
    }

    /// Route a decoded event to whichever turn shape is active: the streaming
    /// sink (which wants every event) or the request-scoped facade (which wants
    /// only the assembled terminal `Response`). The turn gate guarantees exactly
    /// one is active at a time.
    private func route(_ event: ResponsesStreamEvent) {
        if streamSink != nil {
            routeStreaming(event)
        } else {
            routeRequestScoped(event)
        }
    }

    /// Request-scoped routing: terminal events resolve the in-flight turn;
    /// intermediate streaming events (deltas, output-item lifecycle, …) carry
    /// no information the single-`Response` facade needs and are ignored.
    private func routeRequestScoped(_ event: ResponsesStreamEvent) {
        switch event.object {
            case let .responseCompleted(response), let .responseIncomplete(response):
                resolveInFlight(.success(response))
            case let .responseFailed(response):
                resolveInFlight(.failure(responseError(from: response)))
            case let .error(detail):
                resolveInFlight(.failure(openAI.apiError(from: detail)))
            default:
                break
        }
    }

    /// Streaming routing: forward *every* event to the sink, then finish the
    /// stream on a terminal event — normally on completed/incomplete, throwing
    /// the mapped error on failed / an `error` frame.
    private func routeStreaming(_ event: ResponsesStreamEvent) {
        streamSink?.yield(event)
        switch event.object {
            case let .responseCompleted(response), let .responseIncomplete(response):
                recordSuccess(response)
                finishStreaming(.success(()))
            case let .responseFailed(response):
                finishStreaming(.failure(responseError(from: response)))
            case let .error(detail):
                finishStreaming(.failure(openAI.apiError(from: detail)))
            default:
                break
        }
    }

    // MARK: - Send / await plumbing

    private func transmitAndAwait(_ event: ResponsesCreateEvent) async throws -> Response {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
            inFlight = continuation
            Task { await transmit(event) }
        }
    }

    /// Drive one streaming turn: register the sink + completion, send the event,
    /// and suspend (holding the turn gate) until the receive loop reports the
    /// terminal event. Cancellation-safe: if the consumer abandons the stream,
    /// `abortStreaming()` finishes the sink, drops the mid-response socket, and
    /// resumes the completion so the gate is released rather than leaked.
    private func runStream(
        _ event: ResponsesCreateEvent,
        into sink: AsyncThrowingStream<ResponsesStreamEvent, Error>.Continuation
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                streamSink = sink
                streamCompletion = continuation
                Task { await transmit(event) }
            }
        } onCancel: {
            Task { await self.abortStreaming() }
        }
    }

    /// Tear down a streaming turn abandoned by its consumer.
    private func abortStreaming() {
        guard streamSink != nil || streamCompletion != nil else {
            return
        }
        // The socket is mid-response; drop it so the next turn reconnects clean.
        teardown()
        finishStreaming(.failure(CancellationError()))
    }

    private func transmit(_ event: ResponsesCreateEvent) async {
        guard let connection else {
            failActiveTurn(ResponsesWebSocketError.notConnected)
            return
        }

        do {
            let data = try openAI.encoder.encode(event)
            guard let text = String(data: data, encoding: .utf8) else {
                failActiveTurn(ResponsesWebSocketError.encodingFailed)
                return
            }
            try await connection.send(.string(text))
        } catch {
            // The encode is deterministic, so a throw here is the socket
            // rejecting the send — recover it like any other connection loss.
            failActiveTurn(ResponsesWebSocketError.connectionClosed)
        }
    }

    private func resolveInFlight(_ result: Result<Response, Error>) {
        guard let continuation = inFlight else {
            return
        }
        inFlight = nil
        continuation.resume(with: result)
    }

    /// Finish the active streaming turn: terminate the sink (normally or
    /// throwing) and resume the completion that `runStream` is suspended on so
    /// the turn gate releases. Idempotent — a second call is a no-op.
    private func finishStreaming(_ result: Result<Void, Error>) {
        switch result {
            case .success:
                streamSink?.finish()
            case let .failure(error):
                streamSink?.finish(throwing: error)
        }
        streamSink = nil
        if let completion = streamCompletion {
            streamCompletion = nil
            completion.resume(with: result)
        }
    }

    /// Fail whichever turn shape is currently active. Used by the connection-loss
    /// and bad-frame paths, which don't know (or care) which facade is in play.
    private func failActiveTurn(_ error: Error) {
        if inFlight != nil {
            resolveInFlight(.failure(error))
        }
        if streamSink != nil || streamCompletion != nil {
            finishStreaming(.failure(error))
        }
    }

    private func recordSuccess(_ response: Response) {
        guard !response.id.isEmpty else {
            return
        }
        lastResponseId = response.id
    }

    private func responseError(from response: Response) -> Error {
        if let detail = response.error {
            return openAI.apiError(from: detail)
        }
        return APIError.apiError("Responses turn \(response.id) failed without an error detail.")
    }

    // MARK: - Turn gate (async semaphore of 1)

    private func acquireTurn() async {
        if !turnActive {
            turnActive = true
            return
        }
        await withCheckedContinuation { continuation in
            turnWaiters.append(continuation)
        }
    }

    private func releaseTurn() {
        if turnWaiters.isEmpty {
            turnActive = false
        } else {
            // Hand the gate straight to the next waiter; it stays "active".
            turnWaiters.removeFirst().resume()
        }
    }

    // MARK: - Helpers

    private static func isRecoverableConnectionLoss(_ error: Error) -> Bool {
        if let wsError = error as? ResponsesWebSocketError {
            switch wsError {
                case .connectionClosed, .notConnected:
                    return true
                case .missingAPIKey, .encodingFailed:
                    return false
            }
        }
        if let apiError = error as? APIError, case .connectionLimitReached = apiError {
            return true
        }
        return false
    }

    private func websocketRequest(credential: any RequestAuthorizing) throws -> URLRequest {
        guard var components = URLComponents(url: openAI.endpointURL, resolvingAgainstBaseURL: true) else {
            throw URLError(.badURL)
        }

        components.scheme = components.scheme == "https" ? "wss" : "ws"

        let basePath = openAI.endpointURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathComponents = [basePath, openAI.versionPath, "responses"].filter { !$0.isEmpty }
        components.path = "/" + pathComponents.joined(separator: "/")

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        // Bearer only — like the Realtime GA endpoint, the Responses socket
        // rejects an `OpenAI-Beta` header, so this deliberately bypasses
        // `OpenAI.createUrlRequest` (which would add `assistants=v2`).
        var request = URLRequest(url: url)
        credential.authorize(&request)
        return request
    }
}
