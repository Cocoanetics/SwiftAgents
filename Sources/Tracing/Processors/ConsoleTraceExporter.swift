import Foundation
import JSONValue

/**
 A simple console exporter for debugging.

 This exporter prints trace and span data to the console, which is useful for
 debugging and development purposes.
 */
public final class ConsoleTraceExporter: TracingExporter {
    /**
     Exports trace and span data by printing it to the console.

     - Parameter items: The trace and span data to export
     */
    public func export(_ items: [[String: JSONValue]]) async {
        for item in items {
            for (key, value) in item {
                print("[Exporter] Export \(key): \(value)")
            }
        }
    }
}
