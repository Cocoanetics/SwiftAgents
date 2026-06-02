import Foundation
import SwiftMCP
import Tracing

// `@unchecked Sendable`: immutable span-data payload. Its `input`
// (`Response.Input`) is effectively-immutable wire data; mark the payload
// unchecked rather than cascade Sendable through the whole Response model.
/// Represents a Response Span in the trace.
/// Includes response and input.
public struct ResponseSpanData: SpanData, @unchecked Sendable {
    public let response: Response?
    public let input: Response.Input?

    public init(response: Response? = nil, input: Response.Input? = nil) {
        self.response = response
        self.input = input
    }

    public var type: String {
        "response"
    }

    public func export() -> [String: JSONValue] {
        return [
            "type": JSONValue(type),
            "response_id": JSONValue(response?.id)
        ]
    }
}
