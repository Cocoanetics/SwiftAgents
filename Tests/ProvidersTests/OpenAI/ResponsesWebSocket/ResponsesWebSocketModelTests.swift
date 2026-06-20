//
//  ResponsesWebSocketModelTests.swift
//  SwiftAgents
//
//  Drives `OpenAIResponsesWebSocketModel` end-to-end against a scripted,
//  in-memory socket — no network, no API key, fully deterministic. Mirrors the
//  `MockRealtimeModel` pattern in `RealtimeSessionTests`, but at the transport
//  layer: we feed frames in and assert the assembled `Response`, the bytes the
//  transport put on the wire, the chain pointer, error mapping, and reconnect.
//
//  Ordering is made deterministic with `waitForSendCount(_:)`: a test launches
//  the turn with `async let`, waits until its `response.create` is actually on
//  the wire, and only then delivers the terminal frame — so assertions on
//  `sentFrames()` never race the receive loop.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSessionWebSocketTask.Message / .CloseCode live here on Linux
#endif
@testable import Providers
import Testing

// MARK: - Scripted socket

/// A `ResponsesWebSocketConnection` whose inbound frames the test scripts and
/// whose outbound frames the test inspects. Frames pushed before a `receive()`
/// queue up; a `receive()` with an empty queue suspends until the next push.
private final class ScriptedSocket: ResponsesWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var receiveWaiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var sent: [Data] = []
    private var sendCountWaiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var resumeCount = 0
    private(set) var cancelCount = 0

    // MARK: ResponsesWebSocketConnection

    func resume() {
        lock.lock(); resumeCount += 1; lock.unlock()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case let .string(text) = message else { return }
        // Scoped `withLock` rather than bare `lock()`/`unlock()`: the latter is
        // diagnosed as unsafe from an async context (an error in Swift 6 mode).
        let ready = lock.withLock {
            sent.append(Data(text.utf8))
            let count = sent.count
            let waiters = sendCountWaiters.filter { count >= $0.threshold }
            sendCountWaiters.removeAll { count >= $0.threshold }
            return waiters
        }
        ready.forEach { $0.continuation.resume() }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if inbox.isEmpty {
                receiveWaiter = continuation
                lock.unlock()
            } else {
                let next = inbox.removeFirst()
                lock.unlock()
                continuation.resume(with: next)
            }
        }
    }

    func cancel(with _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        lock.lock()
        cancelCount += 1
        let pending = receiveWaiter
        receiveWaiter = nil
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }

    // MARK: Test driver

    /// Queue an inbound text frame (or deliver it to a waiting `receive()`).
    func push(_ json: String) {
        deliver(.success(.string(json)))
    }

    /// Make the in-flight (or next) `receive()` fail, simulating a dropped
    /// socket.
    func drop(_ error: Error = URLError(.networkConnectionLost)) {
        deliver(.failure(error))
    }

    private func deliver(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        lock.lock()
        if let pending = receiveWaiter {
            receiveWaiter = nil
            lock.unlock()
            pending.resume(with: result)
        } else {
            inbox.append(result)
            lock.unlock()
        }
    }

    /// Suspend until this socket has recorded at least `count` outbound frames,
    /// so a test can act once a turn's `response.create` is on the wire — no
    /// sleeps, no races against the receive loop.
    func waitForSendCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if sent.count >= count {
                lock.unlock()
                continuation.resume()
            } else {
                sendCountWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    func sentFrames() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return sent
    }
}

/// Vends a fixed sequence of `ScriptedSocket`s to successive connect calls so a
/// test can script a reconnect. Past the end it keeps returning the last one.
private final class SocketSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let sockets: [ScriptedSocket]
    private var index = 0

    init(_ sockets: [ScriptedSocket]) {
        self.sockets = sockets
    }

    func next() -> ScriptedSocket {
        lock.lock(); defer { lock.unlock() }
        let socket = sockets[min(index, sockets.count - 1)]
        index += 1
        return socket
    }

    func factory() -> ResponsesWebSocketConnectionFactory {
        { _ in self.next() }
    }
}

// MARK: - Fixtures

private func completedFrame(id: String) -> String {
    """
    {
      "type": "response.completed",
      "response": {
        "id": "\(id)",
        "object": "response",
        "created_at": 1741477868,
        "status": "completed",
        "model": "gpt-5.1",
        "output": [],
        "parallel_tool_calls": true,
        "text": { "format": { "type": "text" } },
        "tool_choice": "auto",
        "tools": [],
        "metadata": {}
      }
    }
    """
}

private func errorFrame(code: String, message: String, param: String? = nil) -> String {
    let paramField = param.map { "\"param\": \"\($0)\"," } ?? ""
    return """
    {
      "type": "error",
      "code": "\(code)",
      \(paramField)
      "message": "\(message)"
    }
    """
}

private func textDeltaFrame(_ delta: String) -> String {
    """
    {
      "type": "response.output_text.delta",
      "item_id": "item_1",
      "output_index": 0,
      "content_index": 0,
      "delta": "\(delta)"
    }
    """
}

private func makeTransport(
    _ sockets: SocketSequence,
    maxConnectionAge: TimeInterval = 55 * 60
) -> OpenAIResponsesWebSocketModel {
    OpenAIResponsesWebSocketModel(
        openAI: OpenAI(credential: Credential.bearer("test")),
        maxConnectionAge: maxConnectionAge,
        session: nil,
        connectionFactory: sockets.factory()
    )
}

private func decodeFrame(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - Tests

struct ResponsesWebSocketModelTests {
    @Test("A single turn sends response.create and assembles the completed Response")
    func singleTurn() async throws {
        let socket = ScriptedSocket()
        let transport = makeTransport(SocketSequence([socket]))

        // Deliver the terminal frame only once the request is on the wire, so
        // the sent-frame assertions below never race the response.
        async let turn = transport.send(ResponsesCreateEvent(input: .text("Hello"), model: "gpt-5.1"))
        await socket.waitForSendCount(1)
        socket.push(completedFrame(id: "resp_1"))
        let response = try await turn

        #expect(response.id == "resp_1")
        // The completed id is cached as the fast-continue base.
        let cached = await transport.lastResponseId
        #expect(cached == "resp_1")

        // Exactly one frame went out, and it is a response.create that carries
        // neither `stream` nor `background`.
        let frames = socket.sentFrames()
        #expect(frames.count == 1)
        let body = try decodeFrame(frames[0])
        #expect(body["type"] as? String == "response.create")
        #expect(body["model"] as? String == "gpt-5.1")
        #expect(body["stream"] == nil)
        #expect(body["background"] == nil)
        #expect(body["generate"] == nil)

        await transport.disconnect()
    }

    @Test("Chained turns send only previous_response_id, never stream/background")
    func chainedTurns() async throws {
        let socket = ScriptedSocket()
        let transport = makeTransport(SocketSequence([socket]))

        async let firstTurn = transport.send(ResponsesCreateEvent(input: .text("First"), model: "gpt-5.1"))
        await socket.waitForSendCount(1)
        socket.push(completedFrame(id: "resp_1"))
        _ = try await firstTurn

        async let secondTurn = transport.send(
            ResponsesCreateEvent(
                input: .array([.functionCallOutput(.init(callId: "call_1", output: "5"))]),
                model: "gpt-5.1",
                previousResponseId: "resp_1"
            )
        )
        await socket.waitForSendCount(2)
        socket.push(completedFrame(id: "resp_2"))
        _ = try await secondTurn

        let frames = socket.sentFrames()
        #expect(frames.count == 2)

        let first = try decodeFrame(frames[0])
        #expect(first["previous_response_id"] == nil)

        let second = try decodeFrame(frames[1])
        #expect(second["previous_response_id"] as? String == "resp_1")

        for frame in frames {
            let body = try decodeFrame(frame)
            #expect(body["stream"] == nil)
            #expect(body["background"] == nil)
        }

        await transport.disconnect()
    }

    @Test("A warmup turn carries generate:false")
    func warmupEncodesGenerateFalse() async throws {
        let socket = ScriptedSocket()
        let transport = makeTransport(SocketSequence([socket]))

        let warmup = ResponsesCreateEvent(input: .array([]), model: "gpt-5.1", generate: false)
        async let turn = transport.send(warmup)
        await socket.waitForSendCount(1)
        socket.push(completedFrame(id: "resp_warm"))
        let response = try await turn
        #expect(response.id == "resp_warm")

        let body = try decodeFrame(socket.sentFrames()[0])
        #expect(body["generate"] as? Bool == false)

        await transport.disconnect()
    }

    @Test("An error frame surfaces as a typed APIError and evicts the cache")
    func errorFrameMapsToTypedError() async throws {
        let socket = ScriptedSocket()
        let transport = makeTransport(SocketSequence([socket]))

        async let turn = transport.send(
            ResponsesCreateEvent(input: .text("Hi"), model: "gpt-5.1", previousResponseId: "resp_dead")
        )
        await socket.waitForSendCount(1)
        socket.push(errorFrame(
            code: "previous_response_not_found",
            message: "Previous response not found",
            param: "previous_response_id"
        ))

        // `#expect(throws:)` can't capture an `async let`, so await the turn
        // here and assert the thrown type via do/catch.
        var thrown: (any Error)?
        do {
            _ = try await turn
        } catch {
            thrown = error
        }
        #expect(thrown is APIError)

        // A failed turn drops the cached chain id.
        let cached = await transport.lastResponseId
        #expect(cached == nil)

        await transport.disconnect()
    }

    @Test("previous_response_not_found maps to the dedicated APIError case")
    func previousResponseNotFoundIsDistinct() async throws {
        let socket = ScriptedSocket()
        let transport = makeTransport(SocketSequence([socket]))

        async let turn = transport.send(
            ResponsesCreateEvent(input: .text("Hi"), model: "gpt-5.1", previousResponseId: "resp_dead")
        )
        await socket.waitForSendCount(1)
        socket.push(errorFrame(
            code: "previous_response_not_found",
            message: "Previous response not found",
            param: "previous_response_id"
        ))

        do {
            _ = try await turn
            Issue.record("Expected the send to throw")
        } catch let APIError.previousResponseNotFound(param) {
            #expect(param == "previous_response_id")
        }

        await transport.disconnect()
    }

    @Test("A dropped socket reconnects and re-sends the in-flight turn")
    func reconnectResendsTurn() async throws {
        let first = ScriptedSocket()
        let second = ScriptedSocket()
        let transport = makeTransport(SocketSequence([first, second]))

        // Launch the turn, wait until its `response.create` is on the first
        // connection, then drop that connection mid-turn.
        async let turn = transport.send(ResponsesCreateEvent(input: .text("Hello"), model: "gpt-5.1"))
        await first.waitForSendCount(1)
        first.drop()

        // The transport reconnects and resends; once that resend lands on the
        // second connection, complete it.
        await second.waitForSendCount(1)
        second.push(completedFrame(id: "resp_after_reconnect"))

        let response = try await turn
        #expect(response.id == "resp_after_reconnect")

        // The turn was sent on each connection (original + resend).
        #expect(first.sentFrames().count == 1)
        #expect(second.sentFrames().count == 1)
        // The stale socket was torn down.
        #expect(first.cancelCount >= 1)

        await transport.disconnect()
    }

    @Test("websocket_connection_limit_reached triggers a reconnect")
    func connectionLimitReconnects() async throws {
        let first = ScriptedSocket()
        let second = ScriptedSocket()
        let transport = makeTransport(SocketSequence([first, second]))

        // The server reports the 60-minute cap on the first connection once the
        // turn is on the wire; the transport should reconnect and re-issue it.
        async let turn = transport.send(ResponsesCreateEvent(input: .text("Hi"), model: "gpt-5.1"))
        await first.waitForSendCount(1)
        first.push(errorFrame(
            code: "websocket_connection_limit_reached",
            message: "connection limit reached (60 minutes)"
        ))

        await second.waitForSendCount(1)
        second.push(completedFrame(id: "resp_fresh"))

        let response = try await turn
        #expect(response.id == "resp_fresh")
        #expect(second.sentFrames().count == 1)

        await transport.disconnect()
    }

    @Test("Turns are serialized one-in-flight over a single connection")
    func turnsAreSerialized() async throws {
        let socket = ScriptedSocket()
        let transport = makeTransport(SocketSequence([socket]))

        // Launch two turns concurrently over one connection.
        async let firstTurn = transport.send(ResponsesCreateEvent(input: .text("One"), model: "gpt-5.1"))
        async let secondTurn = transport.send(ResponsesCreateEvent(input: .text("Two"), model: "gpt-5.1"))

        // Exactly one turn reaches the wire; the other is gated behind it. If
        // the transport did not serialize, both frames would appear here.
        await socket.waitForSendCount(1)
        #expect(socket.sentFrames().count == 1)

        // Completing the first turn lets the gated turn send — a second frame
        // appearing only now *proves* it waited.
        socket.push(completedFrame(id: "resp_a"))
        await socket.waitForSendCount(2)
        socket.push(completedFrame(id: "resp_b"))

        let results = try await [firstTurn, secondTurn]
        // Both completed; the two ids map to the two turns (launch order of the
        // async lets is not guaranteed, but both must resolve distinctly).
        #expect(Set(results.map(\.id)) == ["resp_a", "resp_b"])
        #expect(socket.sentFrames().count == 2)

        await transport.disconnect()
    }

    // MARK: - Streaming

    @Test("streamResponse yields every event in order, then finishes on completed")
    func streamYieldsDeltasThenCompletes() async throws {
        let socket = ScriptedSocket()
        let transport = makeTransport(SocketSequence([socket]))

        let stream = transport.streamResponse(ResponsesCreateEvent(input: .text("Hi"), model: "gpt-5.1"))

        // Feed the turn once its `response.create` is on the wire: two text
        // deltas, then the terminal completed frame.
        await socket.waitForSendCount(1)
        socket.push(textDeltaFrame("Hel"))
        socket.push(textDeltaFrame("lo"))
        socket.push(completedFrame(id: "resp_stream"))

        // Collect everything the caller would see.
        var deltas: [String] = []
        var completedId: String?
        for try await event in stream {
            switch event.object {
                case let .outputTextDelta(info):
                    deltas.append(info.delta)
                case let .responseCompleted(response):
                    completedId = response.id
                default:
                    break
            }
        }

        // Deltas arrived in order and the terminal Response closed the stream.
        #expect(deltas == ["Hel", "lo"])
        #expect(completedId == "resp_stream")

        // The completed id seeded the connection-local chain cache.
        let cached = await transport.lastResponseId
        #expect(cached == "resp_stream")

        await transport.disconnect()
    }

    @Test("A streaming error frame throws from the stream and evicts the cache")
    func streamSurfacesErrorFrame() async throws {
        let socket = ScriptedSocket()
        let transport = makeTransport(SocketSequence([socket]))

        let stream = transport.streamResponse(
            ResponsesCreateEvent(input: .text("Hi"), model: "gpt-5.1", previousResponseId: "resp_dead")
        )

        await socket.waitForSendCount(1)
        socket.push(textDeltaFrame("partial"))
        socket.push(errorFrame(
            code: "previous_response_not_found",
            message: "Previous response not found",
            param: "previous_response_id"
        ))

        var sawDelta = false
        var thrown: (any Error)?
        do {
            for try await event in stream {
                if case .outputTextDelta = event.object { sawDelta = true }
            }
        } catch {
            thrown = error
        }

        // The pre-error delta was delivered, then the stream threw the mapped
        // typed error — not a resend (partial output was already emitted).
        #expect(sawDelta)
        if case let .previousResponseNotFound(param)? = thrown as? APIError {
            #expect(param == "previous_response_id")
        } else {
            Issue.record("Expected APIError.previousResponseNotFound, got \(String(describing: thrown))")
        }

        let cached = await transport.lastResponseId
        #expect(cached == nil)

        await transport.disconnect()
    }

    @Test("A streaming turn and a non-streaming turn serialize over one connection")
    func streamingAndRequestScopedSerialize() async throws {
        let socket = ScriptedSocket()
        let transport = makeTransport(SocketSequence([socket]))

        // Start a streaming turn; once it's on the wire, launch a plain send.
        let stream = transport.streamResponse(ResponsesCreateEvent(input: .text("One"), model: "gpt-5.1"))
        await socket.waitForSendCount(1)
        async let secondTurn = transport.send(ResponsesCreateEvent(input: .text("Two"), model: "gpt-5.1"))

        // The gate holds the second turn back: still only one frame on the wire.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(socket.sentFrames().count == 1)

        // Finish the streaming turn; only then can the gated send transmit.
        socket.push(completedFrame(id: "resp_stream"))
        var streamedIds: [String] = []
        for try await event in stream {
            if case let .responseCompleted(response) = event.object { streamedIds.append(response.id) }
        }
        #expect(streamedIds == ["resp_stream"])

        await socket.waitForSendCount(2)
        socket.push(completedFrame(id: "resp_send"))
        let sent = try await secondTurn
        #expect(sent.id == "resp_send")
        #expect(socket.sentFrames().count == 2)

        await transport.disconnect()
    }

    @Test("A malformed recognized frame fails the turn AND tears down the socket")
    func malformedFrameTearsDownSocket() async throws {
        let socket = ScriptedSocket()
        let transport = makeTransport(SocketSequence([socket]))

        // `response.completed` is recognized, but its nested response is missing
        // required fields — a malformed *recognized* payload, which throws.
        async let turn = transport.send(ResponsesCreateEvent(input: .text("Hi"), model: "gpt-5.1"))
        await socket.waitForSendCount(1)
        socket.push(#"{"type":"response.completed","response":{"object":"response"}}"#)

        // `#expect(throws:)` can't capture an `async let`, so await + do/catch.
        var thrown: (any Error)?
        do {
            _ = try await turn
        } catch {
            thrown = error
        }
        #expect(thrown != nil)

        // The connection must be torn down — not merely the turn failed. The
        // server may still be streaming this response's remaining frames, and
        // because frames aren't correlated to a request id, leaving the socket
        // open would let a stale terminal frame resolve a later turn. Dropping
        // the socket (cancel) is what prevents that cross-turn leak.
        #expect(socket.cancelCount >= 1)
        let cached = await transport.lastResponseId
        #expect(cached == nil)

        await transport.disconnect()
    }
}
