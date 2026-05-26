//
//  LMStudioImageInputTests.swift
//  ProvidersTests
//
//  Live image-input tests against LM Studio.
//
//  LM Studio's `/v1/chat/completions` accepts the OpenAI-compat multimodal
//  shape (`image_url` content parts), but the URL field MUST be a base64
//  data URL — remote http URLs are rejected with
//  "'url' field must be a base64 encoded image."
//
//  Gated on `LMSTUDIO_URL` and a vision-capable model
//  (`LMSTUDIO_VISION_MODEL`, default `google/gemma-4-26b-a4b`).
//

import Foundation
@testable import Providers
import SwiftMCP
import Testing

/// A 1x1 solid-red PNG, base64-encoded. Verified to decode and reach
/// LM Studio's vision pipeline correctly — `gemma-4-26b-a4b` reasons
/// "solid red square" against it.
private let solidRedPNG: String =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

private let visionModel = ProcessInfo.processInfo.environment["LMSTUDIO_VISION_MODEL"]
    ?? "google/gemma-4-26b-a4b"

struct LMStudioImageInputTests {
    @Test(
        "createChatCompletion accepts a base64 image part",
        .enabled(if: TestClients.hasLMStudio, "Requires LMSTUDIO_URL")
    )
    func directChatCompletionImageInput() async throws {
        let client = try TestClients.lmStudio()

        let dataURL = "data:image/png;base64,\(solidRedPNG)"
        let userMessage = ChatMessage(
            role: .user,
            content: .parts([
                .init(text: "What colour is this image? Answer in one word."),
                .init(imageURL: dataURL)
            ])
        )

        let completion = try await client.createChatCompletion(
            model: visionModel,
            messages: [userMessage],
            temperature: 0,
            maxCompletionTokens: 200
        )

        let raw = (completion.choices.first?.message.textContent ?? "").lowercased()
        // Reasoning models sometimes prefix the answer; substring match
        // is enough. If LM Studio rejected the image part we'd 400 above.
        #expect(raw.contains("red"))
    }

    @Test(
        "Runner.run accepts a multimodal Response.Input against LM Studio",
        .enabled(if: TestClients.hasLMStudio, "Requires LMSTUDIO_URL")
    )
    func runnerMultimodalInput() async throws {
        let agent = BasicAgent(
            name: "LMStudioVision",
            model: "lmstudio/\(visionModel)",
            instructions: "You are a concise visual assistant. Answer with one word.",
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 200)
        )

        let dataURL = URL(string: "data:image/png;base64,\(solidRedPNG)")!
        let multimodal: Response.Input = .array([
            .message(.init(
                role: .user,
                content: [
                    .inputText("What colour is this image? Answer in one word."),
                    .inputImage(dataURL)
                ]
            ))
        ])

        let result = try await Runner.run(
            agent: agent,
            input: multimodal,
            maxTurns: 2
        )
        #expect(result.finalOutput.lowercased().contains("red"))
    }

    @Test(
        "Session round-trip: image input persisted then replayed across runs",
        .enabled(if: TestClients.hasLMStudio, "Requires LMSTUDIO_URL")
    )
    func sessionImageRoundTrip() async throws {
        let agent = BasicAgent(
            name: "LMStudioVisionMemory",
            model: "lmstudio/\(visionModel)",
            instructions: """
                You are a concise assistant with visual memory. Answer briefly. \
                When asked about an earlier image, recall what colour you saw.
                """,
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 200)
        )

        let session = InMemorySession()
        let dataURL = URL(string: "data:image/png;base64,\(solidRedPNG)")!

        // Wrap both runs in a single `withTrace` so the OpenAI traces
        // dashboard groups them into one top-level trace — two agent
        // spans (one per Runner.run), each with its own Generation span,
        // under one workflow.
        let second = try await withTrace(name: "LM Studio vision memory") {
            _ = try await Runner.run(
                agent: agent,
                input: .array([
                    .message(.init(role: .user, content: [
                        .inputText("Look at this image. What colour is it?"),
                        .inputImage(dataURL)
                    ]))
                ]),
                session: session,
                maxTurns: 2
            )

            // The first turn appended the user image + assistant reply.
            let afterFirst = await session.getItems(limit: nil)
            #expect(afterFirst.count >= 2)
            let sawImage = afterFirst.contains { element in
                if case let .message(msg) = element, msg.role == .user {
                    return msg.content.contains { part in
                        if case .inputImage = part { return true }
                        return false
                    }
                }
                return false
            }
            #expect(sawImage, "expected the user's image part to be persisted in the session")

            // Follow-up turn (plain text) — the model should reference
            // the colour it saw earlier via the replayed session history.
            return try await Runner.run(
                agent: agent,
                input: "What colour was the image I just showed you?",
                session: session,
                maxTurns: 2
            )
        }
        #expect(second.finalOutput.lowercased().contains("red"))
    }

    @Test(
        "Image-input run emits agent + generation spans",
        .enabled(if: TestClients.hasLMStudio, "Requires LMSTUDIO_URL")
    )
    func tracingForImageInput() async throws {
        // Capture every span the global tracer emits during the agent
        // run. Same pattern as `AnthropicResponsesTests.tracesShipToOpenAI`.
        actor Spy: TracingExporter {
            var captured: [[String: JSONValue]] = []
            nonisolated func export(_ items: [[String: JSONValue]]) async {
                await append(items)
            }
            func append(_ items: [[String: JSONValue]]) { captured.append(contentsOf: items) }
            func snapshot() -> [[String: JSONValue]] { captured }
        }
        let spy = Spy()
        // `addProcessor` instead of `setProcessors` so we coexist with any
        // other trace-mutating test running concurrently (e.g. the
        // streaming-trace test) — `setProcessors` replaces and they'd
        // clobber each other. Filtering by agent name below then picks
        // out only the spans we care about.
        await TraceProvider.shared.addProcessor(
            BatchTraceProcessor(exporter: spy, scheduleDelay: 0.1)
        )

        let agentName = "LMStudioVisionTraceProbe"
        let agent = BasicAgent(
            name: agentName,
            model: "lmstudio/\(visionModel)",
            instructions: "Answer with one word.",
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 200)
        )
        let dataURL = URL(string: "data:image/png;base64,\(solidRedPNG)")!

        _ = try await Runner.run(
            agent: agent,
            input: .array([
                .message(.init(role: .user, content: [
                    .inputText("What colour is this image?"),
                    .inputImage(dataURL)
                ]))
            ]),
            maxTurns: 2
        )

        // Wait for the batch processor to flush (scheduleDelay = 100ms).
        try await Task.sleep(for: .milliseconds(500))

        let captured = await spy.snapshot()
        #expect(!captured.isEmpty, "expected the Runner to emit at least one trace/span")

        // Flatten every exported item to JSON. Other trace-emitting tests
        // can share the global TraceProvider in parallel — find OUR
        // run's `trace_id` (the agent span carries this test's agent
        // name) and filter everything else by that id so the assertions
        // stay scoped to this run.
        let encoder = JSONEncoder()
        let flattened = captured.compactMap { item -> String? in
            guard let data = try? encoder.encode(item),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return json
        }
        let anchorJSON = flattened.first(where: { $0.contains(agentName) })
        let anchor = try #require(
            anchorJSON,
            "no spans for \(agentName) in capture: \(flattened.joined(separator: "\n"))"
        )
        let traceID = Self.extractTraceID(from: anchor)
        let resolvedTraceID = try #require(traceID, "expected a trace_id on the agent span")
        let mine = flattened.filter { $0.contains(resolvedTraceID) }
        let joined = mine.joined(separator: "\n")

        // LM Studio image runs route through chat completions (the
        // native `/api/v1/chat` can't handle images), so the per-turn
        // span carries `GenerationSpanData` rather than
        // `ResponseSpanData`. Both span shapes must be present.
        #expect(joined.contains("\"type\":\"agent\""),
                "expected at least one agent span. Captured:\n\(joined)")
        #expect(joined.contains("\"type\":\"generation\""),
                "expected at least one generation span. Captured:\n\(joined)")

        // The image content should appear in the generation span's
        // input — proves the trace export carries the multimodal
        // payload, not just the assistant's textual reply.
        let imageMentioned = joined.contains("data:image/png;base64")
            || joined.contains("image_url")
        #expect(imageMentioned, "expected the image content to appear in at least one exported span")
    }

    @Test(
        "Traces from an LM Studio image run can be ingested by the OpenAI traces backend",
        .enabled(
            if: TestClients.hasLMStudio && APIKey.hasOpenAI,
            "Requires LMSTUDIO_URL and OPENAI_API_KEY"
        )
    )
    func tracesShipToOpenAI() async throws {
        // Same Spy pattern, but here we round-trip the captured spans
        // through `openAI.ingestTraces` — exactly what the
        // BackendSpanExporter does in production. Catches LM-Studio-
        // specific span shapes that pass local assertions but get
        // rejected by OpenAI's traces backend.
        actor Spy: TracingExporter {
            var captured: [[String: JSONValue]] = []
            nonisolated func export(_ items: [[String: JSONValue]]) async {
                await append(items)
            }
            func append(_ items: [[String: JSONValue]]) { captured.append(contentsOf: items) }
            func snapshot() -> [[String: JSONValue]] { captured }
        }
        let spy = Spy()
        await TraceProvider.shared.addProcessor(
            BatchTraceProcessor(exporter: spy, scheduleDelay: 0.1)
        )

        let agentName = "LMStudioImageIngestProbe"
        let agent = BasicAgent(
            name: agentName,
            model: "lmstudio/\(visionModel)",
            instructions: "Answer with one word.",
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 200)
        )
        let dataURL = URL(string: "data:image/png;base64,\(solidRedPNG)")!

        _ = try await Runner.run(
            agent: agent,
            input: .array([
                .message(.init(role: .user, content: [
                    .inputText("What colour is this image?"),
                    .inputImage(dataURL)
                ]))
            ]),
            maxTurns: 2
        )

        try await Task.sleep(for: .milliseconds(500))

        // Scope to this run's spans (trace_id from the agent span).
        let captured = await spy.snapshot()
        let encoder = JSONEncoder()
        let entries = captured.compactMap { entry -> (entry: [String: JSONValue], json: String)? in
            guard let data = try? encoder.encode(entry),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return (entry, json)
        }
        let anchor = try #require(
            entries.first(where: { $0.json.contains(agentName) }),
            "no agent span for \(agentName)"
        )
        guard case let .string(traceID) = anchor.entry["trace_id"] ?? .null else {
            Issue.record("agent span has no trace_id")
            return
        }
        let mine = entries.filter { $0.json.contains(traceID) }.map(\.entry)
        #expect(!mine.isEmpty)

        // The actual ingest call — this is what BackendSpanExporter does
        // every time the default-registered processor flushes. If it
        // throws, that's why traces don't appear on platform.openai.com.
        let openAIKey = try #require(APIKey.openAI as String?)
        let openAI = OpenAI(apiKey: openAIKey)
        try await openAI.ingestTraces(mine)
    }

    @Test(
        "Trace event for an LM Studio run fires exactly once",
        .enabled(if: TestClients.hasLMStudio, "Requires LMSTUDIO_URL")
    )
    func traceEventFiresOnce() async throws {
        // Regression: `withTrace` (ConvenienceFunctions) and
        // `TraceContext.withTrace` (TaskLocal setter) both fired
        // onTraceStart, so the dashboard saw duplicate trace events
        // per Runner.run. Removed the outer notification.
        actor Spy: TracingExporter {
            var captured: [[String: JSONValue]] = []
            nonisolated func export(_ items: [[String: JSONValue]]) async {
                await append(items)
            }
            func append(_ items: [[String: JSONValue]]) { captured.append(contentsOf: items) }
            func snapshot() -> [[String: JSONValue]] { captured }
        }
        let spy = Spy()
        await TraceProvider.shared.addProcessor(
            BatchTraceProcessor(exporter: spy, scheduleDelay: 0.1)
        )

        // Random agent name so we can scope counting in case other tests
        // ran in parallel and shipped their own traces through this spy.
        let agentName = "LMStudioTraceCountAgent_\(UUID().uuidString)"
        let agent = BasicAgent(
            name: agentName,
            model: "lmstudio/\(visionModel)",
            instructions: "Answer with one word.",
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 50)
        )
        _ = try await Runner.run(agent: agent, input: "Reply OK", maxTurns: 2)
        try await Task.sleep(for: .milliseconds(500))

        // Find the trace_id of OUR run by locating the agent span that
        // carries our agent name, then count trace events with that id.
        let captured = await spy.snapshot()
        let encoder = JSONEncoder()
        let agentSpanTraceID: String? = captured.lazy.compactMap { entry -> String? in
            guard let data = try? encoder.encode(entry),
                  let json = String(data: data, encoding: .utf8),
                  json.contains(agentName) else { return nil }
            if case let .string(traceID) = entry["trace_id"] ?? .null { return traceID }
            return nil
        }.first
        let traceID = try #require(agentSpanTraceID, "no agent span for \(agentName)")
        let count = captured.reduce(0) { acc, entry in
            guard case let .string(object) = entry["object"] ?? .null,
                  object == "trace",
                  case let .string(id) = entry["id"] ?? .null,
                  id == traceID else { return acc }
            return acc + 1
        }
        #expect(count == 1, "expected exactly one trace event for our run, got \(count)")
    }

    @Test(
        "Plain-text LM Studio run also ships cleanly to OpenAI traces",
        .enabled(
            if: TestClients.hasLMStudio && APIKey.hasOpenAI,
            "Requires LMSTUDIO_URL and OPENAI_API_KEY"
        )
    )
    func plainTextRunShipsCleanly() async throws {
        // The auto-registered BackendSpanExporter swallows errors with
        // `print(error)`. This test mirrors what it does — and asserts
        // ingest doesn't throw, AND that the workflow name carries the
        // provider so the user can find runs in the traces dashboard.
        actor Spy: TracingExporter {
            var captured: [[String: JSONValue]] = []
            nonisolated func export(_ items: [[String: JSONValue]]) async {
                await append(items)
            }
            func append(_ items: [[String: JSONValue]]) { captured.append(contentsOf: items) }
            func snapshot() -> [[String: JSONValue]] { captured }
        }
        let spy = Spy()
        await TraceProvider.shared.addProcessor(
            BatchTraceProcessor(exporter: spy, scheduleDelay: 0.1)
        )

        let agentName = "LMStudioPlainTextIngestProbe"
        let agent = BasicAgent(
            name: agentName,
            model: "lmstudio/\(visionModel)",
            instructions: "Answer with one word.",
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 50)
        )

        _ = try await Runner.run(
            agent: agent,
            input: "Reply with the word OK.",
            maxTurns: 2
        )
        try await Task.sleep(for: .milliseconds(500))

        let captured = await spy.snapshot()
        let encoder = JSONEncoder()
        let entries = captured.compactMap { entry -> (entry: [String: JSONValue], json: String)? in
            guard let data = try? encoder.encode(entry),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return (entry, json)
        }
        let anchor = try #require(
            entries.first(where: { $0.json.contains(agentName) }),
            "no agent span for \(agentName)"
        )
        guard case let .string(traceID) = anchor.entry["trace_id"] ?? .null else {
            Issue.record("agent span has no trace_id")
            return
        }
        let mine = entries.filter { $0.json.contains(traceID) }.map(\.entry)
        #expect(!mine.isEmpty)

        // The trace event should carry a workflow_name with `lmstudio`
        // so the dashboard groups it visibly.
        let workflowNames = mine.compactMap { entry -> String? in
            guard case let .string(object) = entry["object"] ?? .null,
                  object == "trace",
                  case let .string(name) = entry["workflow_name"] ?? .null else { return nil }
            return name
        }
        #expect(workflowNames.contains { $0.lowercased().contains("lmstudio") },
                "workflow names did not include 'lmstudio': \(workflowNames)")

        // Round-trip the scoped spans through OpenAI's ingest endpoint
        // — what BackendSpanExporter does on every batch flush. A 4xx
        // here is exactly why traces fail to appear on
        // platform.openai.com.
        let openAIKey = try #require(APIKey.openAI as String?)
        let openAI = OpenAI(apiKey: openAIKey)
        try await openAI.ingestTraces(mine)
    }

    /// Pulls the `trace_id` out of a flattened span/trace JSON blob.
    /// Used to scope assertions to a single Runner.run when other tests
    /// share the global TraceProvider.
    private static func extractTraceID(from json: String) -> String? {
        guard let range = json.range(of: "\"trace_id\":\""),
              let end = json[range.upperBound...].firstIndex(of: "\"") else {
            return nil
        }
        return String(json[range.upperBound ..< end])
    }
}
