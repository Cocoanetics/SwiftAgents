import Foundation
import SwiftMCP
import Tracing

/**
 Registers an `OpenAITraceExporter` against the shared `TraceProvider` the
 first time any `OpenAI` client is created, when `OPENAI_API_KEY` is in the
 environment.

 This preserves the convenience that previously lived inside `TraceProvider`'s
 init in the old `OpenAI/Traces/` location — that wiring couldn't move to the
 generic `Tracing` target without leaking an OpenAI dependency the wrong way
 across the module boundary, so it lives here instead and is triggered
 lazily from `OpenAI.init`.

 Tests and apps that want to opt out can either skip setting `OPENAI_API_KEY`
 or call `TraceProvider.shared.setProcessors([])` after the first OpenAI
 instance is constructed.
 */
public enum OpenAITracingAutoConfig {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hasConfigured = false

    /// Idempotent. The first call (with `OPENAI_API_KEY` set) schedules an
    /// `OpenAITraceExporter` registration against `TraceProvider.shared`.
    /// Subsequent calls are a cheap lock + flag check.
    ///
    /// The `hasConfigured` flag is flipped *before* the inner `OpenAI(apiKey:)`
    /// is constructed, so the recursive `OpenAI.init → configureIfNeeded`
    /// chain terminates on the first re-entry.
    public static func configureIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !hasConfigured else { return }
        hasConfigured = true

        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            return
        }
        let openAI = OpenAI(apiKey: apiKey)
        Task.detached {
            await TraceProvider.shared.addProcessor(
                BatchTraceProcessor(exporter: OpenAITraceExporter(openAI: openAI))
            )
        }
    }
}
