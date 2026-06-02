import Foundation
@testable import Providers
import SwiftMCP
import Tracing
import Testing

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

    @Test("String.timestamp keeps the exact OpenAI trace format")
    func timestampFormat() {
        let timestamp = String.timestamp

        // The OpenAI trace ingestion expects exactly this shape:
        //   yyyy-MM-dd'T'HH:mm:ss.SSSSSS+00:00   e.g. 2026-06-02T14:43:15.123456+00:00
        // an ISO-8601 date-time, a PERIOD, exactly SIX fractional (microsecond)
        // digits, and a literal `+00:00` offset. This has held since tracing was
        // introduced; only the clock source ever changed. Guard against drift to
        // 3-digit (milli) or 9-digit (nano) fractions, a comma, or a `Z` offset.
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}\+00:00$"#
        #expect(
            timestamp.range(of: pattern, options: .regularExpression) != nil,
            "String.timestamp '\(timestamp)' must match yyyy-MM-dd'T'HH:mm:ss.SSSSSS+00:00"
        )
    }

    @Test("Span lifecycle records timestamps")
    func spanLifecycle() throws {
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
    func batchProcessorExports() async {
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
