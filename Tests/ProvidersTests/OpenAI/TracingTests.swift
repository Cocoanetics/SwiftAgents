import Foundation
import Testing
@testable import Providers
import SwiftMCP

private actor SpyTraceExporter: TracingExporter {
	private(set) var captured: [[String: JSONValue]] = []

	func export(_ items: [[String: JSONValue]]) async {
		captured.append(contentsOf: items)
	}
}

struct TracingTests {
	@Test("Generated IDs carry expected prefixes")
	func idPrefixes() {
		#expect(String.traceID.hasPrefix("trace_"))
		#expect(String.spanID.hasPrefix("span_"))
		#expect(String.groupID.hasPrefix("group_"))
	}

	@Test("Span lifecycle records timestamps")
	func spanLifecycle() async throws {
		let trace = Trace(id: .traceID, workflowName: "TestWorkflow")
		let span = TraceSpan(
			id: .spanID,
			traceID: trace.id,
			parentID: nil,
			spanData: CustomSpanData(name: "Span", data: [:])
		)

		#expect(!span.startedAt.isEmpty)
		span.end()
		let ended = try #require(span.endedAt, "Expected span to record an end timestamp")
		#expect(!ended.isEmpty)
	}

	@Test("withTrace sets and clears context")
	func traceContext() async throws {
		let result = try await withTrace(name: "Context Trace") {
			#expect(TraceContext.currentTrace?.workflowName == "Context Trace")
			return "done"
		}

		#expect(result == "done")
		#expect(TraceContext.currentTrace == nil)
	}

	@Test("BatchTraceProcessor exports spans")
	func batchProcessorExports() async throws {
		let exporter = SpyTraceExporter()
		let processor = BatchTraceProcessor(exporter: exporter)
		let trace = Trace(id: .traceID, workflowName: "ProcessorWorkflow")

		let span = TraceSpan(
			id: .spanID,
			traceID: trace.id,
			parentID: nil,
			spanData: CustomSpanData(name: "Span", data: [:])
		)

		await processor.onTraceStart(trace)
		await processor.onSpanEnd(span)
		await processor.onTraceEnd(trace)
		await processor.forceFlush()

		let exported = await exporter.captured
		#expect(!exported.isEmpty)
	}
}
