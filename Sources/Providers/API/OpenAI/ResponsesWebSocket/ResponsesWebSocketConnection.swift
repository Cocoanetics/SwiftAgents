//
//  ResponsesWebSocketConnection.swift
//  SwiftAgents
//
//  A minimal seam over a bidirectional message socket. `URLSessionWebSocketTask`
//  satisfies it as-is, so production code is unchanged; tests inject a mock
//  connection and drive the transport entirely offline — no live socket, no
//  API key, deterministic frame ordering.
//
//  The existing Realtime WebSocket models talk to `URLSessionWebSocketTask`
//  directly and therefore can't be unit-tested without a network. This seam
//  is the one structural improvement the Responses transport makes over that
//  blueprint; everything else mirrors it.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The subset of `URLSessionWebSocketTask` the Responses transport relies on.
///
/// Kept deliberately tiny — `resume`, `send`, `receive`, `cancel` — so the
/// mock used in tests is trivial and the real conformance is empty. It is
/// deliberately **not** `Sendable`: the transport actor holds the connection
/// as isolated state and never sends it across an isolation boundary (the
/// receive loop reads it from `self`), so requiring `Sendable` would only
/// force a needless `@unchecked` on `URLSessionWebSocketTask`.
///
/// Public so advanced callers can supply a custom transport (a proxy, an
/// instrumented socket) via ``OpenAIResponsesWebSocket``'s `connectionFactory`.
public protocol ResponsesWebSocketConnection: AnyObject, Sendable {
    /// Begin the socket handshake. Mirrors `URLSessionTask.resume()`.
    func resume()

    /// Send one message frame.
    func send(_ message: URLSessionWebSocketTask.Message) async throws

    /// Await the next inbound message frame. Throws when the socket closes or
    /// errors.
    func receive() async throws -> URLSessionWebSocketTask.Message

    /// Close the socket with the given code.
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

/// `URLSessionWebSocketTask` already exposes exactly this surface.
extension URLSessionWebSocketTask: ResponsesWebSocketConnection {}

/// Builds a connection for a handshake request. Injected so tests can swap in
/// a mock; defaults to a real `URLSessionWebSocketTask` from the given session.
public typealias ResponsesWebSocketConnectionFactory =
    @Sendable (_ request: URLRequest) -> any ResponsesWebSocketConnection
