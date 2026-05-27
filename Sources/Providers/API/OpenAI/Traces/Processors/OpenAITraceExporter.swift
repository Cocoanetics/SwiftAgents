import Foundation
import SwiftMCP
import Tracing

/**
  Exports trace and span data to the OpenAI traces ingest endpoint.

  Wrap in a `BatchTraceProcessor` to register against the global `TraceProvider`:
  ```swift
  await TraceProvider.shared.addProcessor(
      BatchTraceProcessor(exporter: OpenAITraceExporter(openAI: openAI))
  )
  ```
 */
public actor OpenAITraceExporter: TracingExporter {
    let openAI: OpenAI

    public init(openAI: OpenAI) {
        self.openAI = openAI
    }

    public nonisolated func export(_ items: [[String: JSONValue]]) async {
        do {
            try await openAI.ingestTraces(items)
        } catch {
            print(error)
        }
    }
}
