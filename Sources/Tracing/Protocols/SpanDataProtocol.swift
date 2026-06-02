import Foundation
import SwiftMCP

/**
 Represents span data in a trace.

 Implement this protocol to define custom types of span data that can be
 exported as part of a trace.
 */
public protocol SpanData: Sendable {
    /** Returns the type identifier for this span data. */
    var type: String { get }

    /**
     Exports the span data as a dictionary.

     - Returns: A dictionary representation of the span data that can be serialized.
     */
    func export() -> [String: JSONValue]
}
