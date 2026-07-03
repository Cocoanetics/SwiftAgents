//
//  ToolOutputSerialization.swift
//  SwiftAgents
//
//  The single "tool result → model-visible string" serializer, shared by
//  every path that feeds a tool call's result back to the model.

import Foundation

/// Serializes tool-call results into the text handed back to the model.
///
/// Policy (deliberately fixed in one place so all run paths render results
/// identically): `String` results pass through verbatim — no extra quotes —
/// and everything else is encoded as compact JSON (cheapest in tokens) with
/// `.iso8601` dates. UTC ('Z') is kept on purpose: it is host-independent,
/// unlike `JSONCoding.makeValueEncoder()`'s `.iso8601WithTimeZone`, which
/// renders local offsets.
package enum ToolOutputSerialization {
    /// Returns the model-visible string for a tool result: the value itself
    /// when it already is a `String`, otherwise its compact JSON encoding.
    package static func string(from result: any Encodable & Sendable) throws -> String {
        if let string = result as? String {
            return string
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(result)
        // JSONEncoder output is always valid UTF-8 — the fallback is unreachable.
        return String(bytes: data, encoding: .utf8) ?? "Error: Failed to serialize JSON result"
    }
}
