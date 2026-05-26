import Foundation
import SwiftMCP

// MARK: - Convenience Functions

/**
 Creates and manages a span for the duration of an operation.

 This function handles creating a span, setting it as the current span in the context,
 executing the operation, and then marking the span as complete when the operation finishes.
 It also handles error propagation and notification of processors.

 - Parameter id: The identifier for the span, defaults to a generated ID
 - Parameter traceID: The identifier of the trace this span belongs to, defaults to the current trace's ID
 - Parameter parentID: The identifier of the parent span, defaults to the current span's ID
 - Parameter spanData: Optional data to associate with the span
 - Parameter operation: The operation to execute within the span
 - Returns: The result of the operation
 - Throws: Any error thrown by the operation, after capturing it in the span
 */
@discardableResult
public func withSpan<T>(
    id: String = .spanID,
    traceID: String? = nil,
    parentID: String? = nil,
    spanData: SpanData? = nil,
    operation: (TraceSpan) async throws -> T
) async throws -> T {
    // 1. Determine Trace ID
    let effectiveTraceID: String = try {
        if let providedTraceID = traceID { return providedTraceID }
        if let currentTraceID = TraceContext.currentTrace?.id { return currentTraceID }
        throw TraceError.missingTraceContext
    }()

    // 2. Determine Parent ID (respect explicitly passed nil)
    let effectiveParentID: String? = parentID ?? TraceContext.currentSpan?.id

    // 3. Create the Span
    let span = TraceSpan(
        id: id,
        traceID: effectiveTraceID,
        parentID: effectiveParentID,
        startedAt: .timestamp,
        spanData: spanData
    )

    // 4. Notify Processors: Span Start
    await TraceProvider.shared.processorsActor.notifyProcessors { await $0.onSpanStart(span) }

    // 5. Execute Operation within Span Context
    var operationResult: T?
    var operationError: Error?

    do {
        // Set the current span for the duration of the operation
        if T.self == Void.self {
            try await TraceContext.withSpan(span) {
                _ = try await operation(span) // Explicitly discard result
            }
            operationResult = () as? T
        } else {
            var result: T?
            try await TraceContext.withSpan(span) {
                result = try await operation(span) // Capture result
            }
            operationResult = result
        }
    } catch let error as RunnerError {
        switch error {
            case .exceededMaxTurns:
                span.error = SpanError(message: "Exceeded maximum number of turns")
        }

        operationError = error
    } catch let error as InputGuardrailTripwireTriggered {
        let data: [String: JSONValue] = ["guardrail": JSONValue(error.guardrailName)]
        span.error = SpanError(message: "Input guardrail tripwire triggered", data: data)
        operationError = error
    } catch let error as OutputGuardrailTripwireTriggered {
        let data: [String: JSONValue] = ["guardrail": JSONValue(error.guardrailName)]
        span.error = SpanError(message: "Output guardrail tripwire triggered", data: data)
        operationError = error
    } catch {
        // Capture error details in the span
        span.error = SpanError(message: error.localizedDescription)
        operationError = error
    }

    // 6. Mark Span as Ended
    span.end() // Sets endedAt

    // 7. Notify Processors: Span End
    await TraceProvider.shared.processorsActor.notifyProcessors { await $0.onSpanEnd(span) }

    // 8. Handle Result/Error
    if let error = operationError {
        throw error
    } else if let result = operationResult {
        return result
    } else if T.self == Void.self {
        // If T is Void and operationResult is nil, return empty tuple
        // swiftlint:disable:next force_cast - guarded above by `T.self == Void.self`.
        return () as! T
    } else {
        throw TraceError.unexpectedNilResult
    }
}

/**
 Creates and manages a trace for the duration of an operation.
 If there's already an active trace, it will reuse that trace instead of creating a new one.

 This function either reuses the current trace or creates a new one if none exists,
 executes the operation, and notifies processors at the start and end of the trace
 (only for newly created traces).

 - Parameter name: The name of the workflow this trace represents (used only if creating a new trace)
 - Parameter traceID: The identifier for the trace, defaults to a generated ID (used only if creating a new trace)
 - Parameter groupID: Optional group identifier to associate related traces (used only if creating a new trace)
 - Parameter metadata: Optional metadata to associate with the trace (used only if creating a new trace)
 - Parameter operation: The operation to execute within the trace
 - Returns: The result of the operation
 - Throws: Any error thrown by the operation
 */
public func withTrace<T>(
    name: String,
    traceID: String = .traceID, // Generate ID by default
    groupID: String? = nil,
    metadata: [String: String]? = nil,
    operation: () async throws -> T
) async throws -> T {
    let traceToUse = TraceContext.currentTrace ?? Trace(
        id: traceID,
        workflowName: name,
        groupID: groupID,
        metadata: metadata
    )

    // `TraceContext.withTrace` already fires onTraceStart / onTraceEnd
    // when the id differs from the active task-local trace; don't
    // double-fire here.
    var operationResult: T?
    var operationError: Error?

    do {
        operationResult = try await TraceContext.withTrace(traceToUse) {
            try await operation()
        }
    } catch {
        operationError = error
    }

    if let errorToThrow = operationError {
        throw errorToThrow
    } else if let result = operationResult {
        return result
    } else if T.self == Void.self {
        // swiftlint:disable:next force_cast - guarded above by `T.self == Void.self`.
        return () as! T
    } else {
        throw TraceError.unexpectedNilResult
    }
}
