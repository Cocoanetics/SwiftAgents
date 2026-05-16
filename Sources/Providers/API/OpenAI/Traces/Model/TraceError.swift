import Foundation

// MARK: - Error Handling

/*
 Defines errors that can occur within the tracing system.
 */
public enum TraceError: Error, LocalizedError {
	/* Indicates that a span couldn't be created because no trace context was available */
	case missingTraceContext
	/* Indicates that an operation completed but returned an unexpected nil result */
	case unexpectedNilResult

	/*
	 Returns a localized description of the error.
	 
	 - Returns: A human-readable description of the error
	 */
	public var errorDescription: String? {
		switch self {
		case .missingTraceContext:
			return "Cannot create span: No active trace found in context and no traceID provided."
		case .unexpectedNilResult:
			return "Span operation completed successfully but returned an unexpected nil result."
		}
	}
}
