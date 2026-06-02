import Foundation
import JSONValue

// `@unchecked Sendable`: a span is created, mutated (`end()`, `spanData`,
// `error`), and ended within its owning task before being handed to the
// actor-isolated processors, so its mutable fields aren't touched
// concurrently. It stays a reference type so `end()` updates propagate
// through the `TraceContext.currentSpan` task-local.
/**
 Represents a single span within a trace.

 A span represents a unit of work or operation within a trace. It can contain
 specific data about the operation and can be nested within other spans.
 */
public final class TraceSpan: Identifiable, @unchecked Sendable {
    /** Unique identifier for the span */
    public let id: String
    /** Identifier of the trace this span belongs to */
    public let traceID: String
    /** Optional identifier of the parent span, if this is a nested span */
    public let parentID: String?
    /** Time when the span started */
    public let startedAt: String
    /** Time when the span ended, if it has completed */
    public var endedAt: String?
    /** Data associated with this span */
    public var spanData: SpanData?
    /** Error information, if an error occurred during this span */
    public var error: SpanError?

    /**
     Creates a new trace span.

     - Parameter id: Unique identifier for the span
     - Parameter traceID: Identifier of the trace this span belongs to
     - Parameter parentID: Optional identifier of the parent span
     - Parameter startedAt: Time when the span started, defaults to current time
     - Parameter endedAt: Optional time when the span ended
     - Parameter spanData: Optional data associated with this span
     - Parameter error: Optional error information
     */
    public init(
        id: String,
        traceID: String,
        parentID: String? = nil,
        startedAt: String = .timestamp,
        endedAt: String? = nil,
        spanData: SpanData? = nil,
        error: SpanError? = nil
    ) {
        self.id = id
        self.traceID = traceID
        self.parentID = parentID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.spanData = spanData
        self.error = error
    }

    /**
     Marks the span as completed by setting the end time to the current time.
     */
    public func end() {
        endedAt = .timestamp
    }
}

// MARK: - TraceSpan Extension

public extension TraceSpan {
    /**
     Exports the span as a dictionary.

     - Returns: A dictionary representation of the span that can be serialized
     */
    func export() -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "object": JSONValue("trace.span"),
            "id": JSONValue(id),
            "trace_id": JSONValue(traceID),
            "started_at": JSONValue(startedAt)
        ]

        if let parentID {
            result["parent_id"] = JSONValue(parentID)
        }

        if let endedAt {
            result["ended_at"] = JSONValue(endedAt)
        }

        if let spanData {
            result["span_data"] = JSONValue(spanData.export())
        }

        if let error {
            result["error"] = JSONValue(error)
        } else {
            result["error"] = JSONValue(nil)
        }

        return result
    }
}
