import Foundation
import JSONValue

/**
 Errors that want custom rendering on a span can conform to this protocol.

 `withSpan` catches `TracedError` before the generic `Error` fallback so the
 caller-supplied message and data land on `SpanError` instead of
 `error.localizedDescription`.
 */
public protocol TracedError: Error {
    /** Human-readable message recorded on the span when this error is caught. */
    var spanErrorMessage: String { get }
    /** Optional structured data attached to the span error. */
    var spanErrorData: [String: JSONValue]? { get }
}

public extension TracedError {
    var spanErrorData: [String: JSONValue]? { nil }
}
