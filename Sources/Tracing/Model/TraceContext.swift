import Foundation

// MARK: - Context Management

/**
 Provides task-local storage for trace and span context.

 The TraceContext allows propagating trace and span information through the call stack
 without explicitly passing them as parameters.
 */
public enum TraceContext {
    /** The current active trace in the execution context */
    @TaskLocal public static var currentTrace: Trace?
    /** The current active span in the execution context */
    @TaskLocal public static var currentSpan: TraceSpan?

    /**
     Executes an operation with the specified trace as the current trace.

     - Parameter trace: The trace to set as current
     - Parameter operation: The operation to execute within the trace context
     - Returns: The result of the operation
     - Throws: Any error thrown by the operation
     */
    public static func withTrace<T>(
        _ trace: Trace,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async throws -> T {
        let needsNotification = currentTrace?.id != trace.id

        if needsNotification {
            await TraceProvider.shared.processorsActor.notifyProcessors { await $0.onTraceStart(trace) }
        }

        let result = try await $currentTrace.withValue(trace) {
            try await operation()
        }

        if needsNotification {
            await TraceProvider.shared.processorsActor.notifyProcessors { await $0.onTraceEnd(trace) }
        }

        return result
    }

    /**
     Executes an operation with the specified span as the current span.

     - Parameter span: The span to set as current
     - Parameter operation: The operation to execute within the span context
     - Throws: Any error thrown by the operation
     */
    public static func withSpan(
        _ span: TraceSpan,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Void
    ) async throws {
        try await $currentSpan.withValue(span) {
            try await operation()
        }
    }

    /**
     Executes an operation with no current span in the context.

     - Parameter operation: The operation to execute with no span context
     - Throws: Any error thrown by the operation
     */
    public static func clearCurrentSpan(
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Void
    ) async throws {
        try await $currentSpan.withValue(nil) {
            try await operation()
        }
    }
}
