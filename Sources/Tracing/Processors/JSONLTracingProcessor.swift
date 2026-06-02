import Foundation
import JSONValue

/**
 A `TracingProcessor` that writes one JSON-line per trace/span lifecycle event
 to a single append-only file.

 Each call to `onTraceStart`, `onSpanStart`, `onSpanEnd`, `onTraceEnd` emits
 one line, prefixed with `"type"` (`trace_start` / `trace_end` / `span_start`
 / `span_end`) and including the `trace_id` so multiple concurrent traces can
 share a single file and be demultiplexed downstream.

 Intermediate directories are created if missing. The file handle is opened
 lazily on first write, kept open for the processor's lifetime, and closed on
 `shutdown()` / `forceFlush()` — both flush to disk.
 */
public actor JSONLTracingProcessor: TracingProcessor {
    private let fileURL: URL
    private var handle: FileHandle?
    private var isShutdown = false

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - TracingProcessor

    public func onTraceStart(_ trace: Trace) async {
        var line = trace.export()
        line["type"] = JSONValue("trace_start")
        append(line)
    }

    public func onTraceEnd(_ trace: Trace) async {
        var line = trace.export()
        line["type"] = JSONValue("trace_end")
        append(line)
    }

    public func onSpanStart(_ span: TraceSpan) async {
        var line = span.export()
        line["type"] = JSONValue("span_start")
        append(line)
    }

    public func onSpanEnd(_ span: TraceSpan) async {
        var line = span.export()
        line["type"] = JSONValue("span_end")
        append(line)
    }

    public func shutdown() async {
        flushAndClose()
        isShutdown = true
    }

    public func forceFlush() async {
        try? handle?.synchronize()
    }

    // MARK: - File I/O

    private func append(_ line: [String: JSONValue]) {
        guard !isShutdown else { return }

        do {
            let handle = try openHandleIfNeeded()
            let data = try Self.encoder.encode(JSONValue.object(line))
            handle.write(data)
            handle.write(Data([0x0A])) // newline
        } catch {
            // Surface unexpected I/O errors but never crash a span lifecycle.
            print("JSONLTracingProcessor: failed to write line: \(error)")
        }
    }

    private func openHandleIfNeeded() throws -> FileHandle {
        if let handle { return handle }

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        self.handle = handle
        return handle
    }

    private func flushAndClose() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }
}
