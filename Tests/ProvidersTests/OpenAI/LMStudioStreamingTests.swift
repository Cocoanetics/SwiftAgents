//
//  LMStudioStreamingTests.swift
//  ProvidersTests
//
//  Smoke tests for the Agents SDK streaming runner against an
//  OpenAI-compatible local server (LM Studio). Verifies that:
//
//  1. The dispatcher now routes LM Studio (an `OpenAI` instance with a
//     non-`api.openai.com` endpoint) through the chat-completion streaming
//     path, not the Responses path which LM Studio doesn't implement.
//  2. The runner sees multiple text deltas instead of one synthetic event.
//
//  Gated on `LMSTUDIO_URL` being set so CI without a local server skips.
//

import Foundation
@testable import Providers
import SwiftMCP
import Testing

struct LMStudioStreamingTests {
    private static let hasLMStudio = ProcessInfo.processInfo.environment["LMSTUDIO_URL"] != nil
    private let model = "google/gemma-4-26b-a4b"

    @Test(
        "LM Studio runner streams text deltas",
        .enabled(if: Self.hasLMStudio, "Requires LMSTUDIO_URL")
    )
    func runnerStreamingViaLMStudio() async throws {
        // The shared Providers registry creates the LM Studio API instance
        // lazily on first lookup and reads LMSTUDIO_URL at that moment.
        _ = try await Providers.shared.api(for: "lmstudio/\(model)")

        let agent = BasicAgent(
            name: "LMStudioStreamer",
            model: "lmstudio/\(model)",
            instructions: "You are a concise assistant. Reply with one short sentence.",
            modelSettings: ModelSettings(temperature: 0)
        )

        let result = Runner.runStreamed(
            agent: agent,
            input: "Why is token-by-token streaming useful for chat UIs?",
            maxTurns: 2
        )

        var deltaCount = 0
        var accumulated = ""
        var sawMessage = false
        for try await event in result.events {
            switch event {
                case let .rawResponseEvent(raw):
                    if case let .outputTextDelta(info) = raw.object {
                        deltaCount += 1
                        accumulated += info.delta
                    }
                case let .runItemEvent(_, item):
                    if case let .message(text) = item, !text.isEmpty {
                        sawMessage = true
                    }
                default:
                    continue
            }
        }

        // The whole point of routing LM Studio through the chat-completion
        // streaming path is that the consumer sees real per-token deltas
        // instead of one synthetic event at the end.
        #expect(deltaCount > 1, "Expected multiple text deltas, got \(deltaCount)")
        #expect(!accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(sawMessage)
    }

    @Test(
        "LM Studio streaming runner emits traces",
        .enabled(if: Self.hasLMStudio, "Requires LMSTUDIO_URL")
    )
    func runnerStreamingEmitsTraces() async throws {
        _ = try await Providers.shared.api(for: "lmstudio/\(model)")

        // Capture every span the global tracer emits during the streamed run.
        actor Spy: TracingExporter {
            var captured: [[String: JSONValue]] = []
            nonisolated func export(_ items: [[String: JSONValue]]) async {
                await append(items)
            }
            func append(_ items: [[String: JSONValue]]) { captured.append(contentsOf: items) }
            func snapshot() -> [[String: JSONValue]] { captured }
        }
        let spy = Spy()
        // `addProcessor` rather than `setProcessors` so we coexist with
        // any other trace-mutating test running concurrently — both
        // `setProcessors` calls would otherwise clobber each other.
        // Filtering by agent name below keeps assertions scoped to this
        // test's run.
        await TraceProvider.shared.addProcessor(
            BatchTraceProcessor(exporter: spy, scheduleDelay: 0.1)
        )

        let agentName = "LMStudioTraceProbe"
        let agent = BasicAgent(
            name: agentName,
            model: "lmstudio/\(model)",
            instructions: "Reply with exactly the word OK.",
            modelSettings: ModelSettings(temperature: 0)
        )

        let result = Runner.runStreamed(agent: agent, input: "go", maxTurns: 2)
        for try await _ in result.events {}

        // Allow the BatchTraceProcessor to flush (scheduleDelay = 100ms).
        try await Task.sleep(for: .milliseconds(500))

        let captured = await spy.snapshot()
        #expect(!captured.isEmpty, "Expected the streaming Runner to emit spans")

        // Sanity-check the same span types the non-streaming chat-completion
        // path emits — agent span + generation span — show up here too.
        // First find our agent span (only one with this agentName) and
        // its trace_id, then filter the rest of the capture by that id
        // so concurrent unrelated runs don't pollute the assertion. The
        // generation span doesn't carry the agent name, so filtering by
        // name alone misses it.
        let encoder = JSONEncoder()
        let entries = captured.compactMap { entry -> (entry: [String: JSONValue], json: String)? in
            guard let data = try? encoder.encode(entry),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return (entry, json)
        }
        guard let anchor = entries.first(where: { $0.json.contains(agentName) }),
              case let .string(traceID) = anchor.entry["trace_id"] ?? .null else {
            Issue.record("no agent span for \(agentName); captured: \(entries.map(\.json).joined(separator: "\n"))")
            return
        }
        let mine = entries.filter { $0.json.contains(traceID) }
        #expect(!mine.isEmpty)

        let spanTypes = mine.compactMap { pair -> String? in
            guard case let .object(spanData) = pair.entry["span_data"] ?? .null else { return nil }
            if case let .string(type) = spanData["type"] ?? .null { return type }
            return nil
        }
        #expect(spanTypes.contains("agent"))
        #expect(spanTypes.contains("generation"))

        // The workflow name should carry the inferred provider so the OpenAI
        // traces dashboard surfaces it at a glance.
        let workflowNames = mine.compactMap { pair -> String? in
            guard case let .string(object) = pair.entry["object"] ?? .null, object == "trace" else { return nil }
            if case let .string(name) = pair.entry["workflow_name"] ?? .null { return name }
            return nil
        }
        #expect(workflowNames.contains { $0.contains("lmstudio") }, "Got workflow names: \(workflowNames)")
    }
}
