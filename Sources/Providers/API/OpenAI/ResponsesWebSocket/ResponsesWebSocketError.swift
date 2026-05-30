//
//  ResponsesWebSocketError.swift
//  SwiftAgents
//
//  Transport-level failures for the Responses WebSocket. Server-reported
//  problems (a bad `previous_response_id`, the 60-minute connection cap) are
//  surfaced as `APIError` cases so they read the same whether they arrive over
//  HTTP or the socket; this enum covers only the conditions that are unique to
//  owning a long-lived connection.
//

import Foundation

/// Failures specific to the persistent Responses WebSocket transport.
public enum ResponsesWebSocketError: LocalizedError {
    /// A turn was dispatched before the socket was connected and it could not
    /// be brought up.
    case notConnected

    /// The socket closed (or errored) while a turn was in flight. Recoverable:
    /// the transport reconnects and re-sends the turn.
    case connectionClosed

    /// `OPENAI_API_KEY` (or an explicitly supplied key) is required to open the
    /// socket.
    case missingAPIKey

    /// An encoded event could not be represented as UTF-8 text.
    case encodingFailed

    public var errorDescription: String? {
        switch self {
            case .notConnected:
                return "The Responses WebSocket is not connected."
            case .connectionClosed:
                return "The Responses WebSocket closed while a turn was in flight."
            case .missingAPIKey:
                return "OPENAI_API_KEY is required to open a Responses WebSocket."
            case .encodingFailed:
                return "Unable to encode a Responses event as UTF-8 text."
        }
    }
}
