//
//  SSEDataSequence.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 03.07.26.
//
//  Shared plumbing for the provider SSE streaming endpoints. The framing —
//  previously hand-rolled in four diverging loops — runs through
//  JSONRPCWire's spec-correct incremental `SSEEventDecoder`.

import Foundation
import JSONRPCWire
import SwiftCross

/// Namespace for wire-level SSE constants shared by the streaming surfaces.
enum SSE {
    /// The `data: [DONE]` terminal sentinel of OpenAI-style streams. It is
    /// ordinary event data per the SSE spec, so callers check for it at the
    /// payload level.
    static let doneSentinel = Data("[DONE]".utf8)
}

/// Spec-correct incremental SSE framing over any byte sequence.
///
/// Wraps `JSONRPCWire.SSEEventDecoder`: comment lines, CRLF line endings,
/// multi-line `data:` fields (joined with `\n`), and blank-line dispatch are
/// all handled per the `text/event-stream` spec. Each element is the complete
/// `data` payload of one dispatched event. `event:` names are not surfaced —
/// the surfaces that need a discriminator read it from the payload's `type`
/// field, which both the OpenAI Responses API and Anthropic mirror into the
/// JSON. (The Assistants loop, whose payloads don't carry the fully-qualified
/// event name, keeps line-level framing instead — see `OpenAI+Runs.swift`.)
///
/// Generic over the byte source rather than taking `URLSession.AsyncBytes`
/// directly so the framing is testable offline with canned transcripts.
struct SSEDataSequence<Bytes: AsyncSequence & Sendable>: AsyncSequence, Sendable where Bytes.Element == UInt8 {
    typealias Element = Data

    let bytes: Bytes

    struct AsyncIterator: AsyncIteratorProtocol {
        var byteIterator: Bytes.AsyncIterator
        var decoder = SSEEventDecoder()
        var lineBuffer = Data()
        var pending: [Data] = []

        mutating func next() async throws -> Data? {
            if !pending.isEmpty {
                return pending.removeFirst()
            }

            while let byte = try await byteIterator.next() {
                lineBuffer.append(byte)

                guard byte == UInt8(ascii: "\n") else { continue }

                // Feed the decoder one complete line at a time; it buffers
                // across pushes, so granularity only affects allocation.
                pending = decoder.push(lineBuffer)
                lineBuffer.removeAll(keepingCapacity: true)

                if !pending.isEmpty {
                    return pending.removeFirst()
                }
            }

            // Per spec an event is only dispatched by a blank line; an
            // incomplete event at EOF is discarded.
            return nil
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(byteIterator: bytes.makeAsyncIterator())
    }
}

extension API {
    /// Shared non-200 preamble for the SSE streaming endpoints: when the
    /// response is HTTP with a non-200 status, drains the remaining body (so
    /// the error payload is complete) and throws the mapped error.
    ///
    /// The error mapping stays a parameter because the providers differ:
    /// the OpenAI-family loops pass `errorFromResponse`, Anthropic passes
    /// `anthropicError(from:response:)`. Non-HTTP responses pass through —
    /// callers keep their own policy for those.
    func throwIfStreamError(
        response: URLResponse,
        asyncBytes: URLSession.AsyncBytes,
        mapError: (Data, HTTPURLResponse) -> Error
    ) async throws {
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 else {
            return
        }

        // Read until end so the error body is complete.
        let data = try await asyncBytes.reduce(into: Data()) { partialResult, byte in
            partialResult.append(byte)
        }

        throw mapError(data, httpResponse)
    }
}
