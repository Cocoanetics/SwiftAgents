import Foundation

/*
 Protocol defining the interface for trace processors.
 
 Trace processors receive notifications about trace and span lifecycle events
 and can perform actions such as exporting or storing trace data.
 */
public protocol TracingProcessor {
	/*
	 Called when a trace is started.
	 
	 - Parameter trace: The trace that was started
	 */
	func onTraceStart(_ trace: Trace) async

	/*
	 Called when a trace is ended.
	 
	 - Parameter trace: The trace that was ended
	 */
	func onTraceEnd(_ trace: Trace) async

	/*
	 Called when a span is started.
	 
	 - Parameter span: The span that was started
	 */
	func onSpanStart(_ span: TraceSpan) async

	/*
	 Called when a span is ended.
	 
	 - Parameter span: The span that was ended
	 */
	func onSpanEnd(_ span: TraceSpan) async

	/*
	 Shuts down the processor, allowing it to release resources and perform final exports.
	 */
	func shutdown() async

	/*
	 Forces the processor to export any pending traces and spans immediately.
	 */
	func forceFlush() async
}
