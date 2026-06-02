import Foundation
import JSONValue

/**
 Represents an error associated with a span.

 Used to capture error information that occurred during a span's execution.
 */
public struct SpanError: Codable {
    /** The error message describing what went wrong */
    public let message: String

    public let data: [String: JSONValue]?
    /**
     Creates a new span error.

     - Parameter message: The error message describing what went wrong
     */
    public init(message: String, data: [String: JSONValue]? = nil) {
        self.message = message
        self.data = data
    }
}
