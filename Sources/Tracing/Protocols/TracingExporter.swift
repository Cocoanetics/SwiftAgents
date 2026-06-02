import Foundation
import SwiftMCP

/**
 Protocol defining the interface for trace exporters.

 Trace exporters are responsible for exporting traces and spans to an external system,
 such as a logging service, a monitoring system, or a storage backend.
 */
public protocol TracingExporter: Sendable {
    /**
     Exports a collection of trace or span items.

     - Parameter items: A collection of serialized trace and span data to export
     */
    func export(_ items: [[String: JSONValue]]) async
}
