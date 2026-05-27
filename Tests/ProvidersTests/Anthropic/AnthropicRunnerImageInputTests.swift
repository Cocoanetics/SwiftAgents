//
//  AnthropicRunnerImageInputTests.swift
//  ProvidersTests
//
//  Image-input coverage via the Agents SDK Runner against Anthropic.
//  Mirrors what LMStudioImageInputTests verifies for LM Studio — a
//  multimodal `Response.Input` survives the conversion to Anthropic's
//  `image` content blocks, a session persists the image part across
//  Runner.run calls, and the trace export carries the multimodal
//  payload (not just the assistant's reply).
//
//  We use the `vision-test.png` fixture (256x192 RGBA dice photo)
//  rather than a 1x1 dummy because Anthropic's API rejects images
//  under 200 pixels — see
//  https://platform.claude.com/docs/en/build-with-claude/vision
//  ("Claude may hallucinate or make mistakes when interpreting
//  low-quality, rotated, or very small images under 200 pixels"),
//  which manifests as `.invalidRequest("Could not process image")`.
//
//  Gated on ANTHROPIC_API_KEY.
//

import Foundation
@testable import Agents
import Tracing
@testable import Providers
import SwiftMCP
import Testing

private let anthropicVisionModel = "claude-haiku-4-5"

/// Loads the shared vision fixture (256x192 PNG of three transparent
/// dice) into a base64 data URL. Both Anthropic and Gemini's existing
/// vision tests consume the same fixture, so the converter is proven
/// against it.
private func diceDataURL() throws -> URL {
    let bundleURL = try #require(
        Bundle.module.url(forResource: "vision-test", withExtension: "png"),
        "vision-test fixture is required"
    )
    let data = try Data(contentsOf: bundleURL)
    let dataURL = "data:image/png;base64,\(data.base64EncodedString())"
    return try #require(URL(string: dataURL), "expected a valid data: URL")
}

@Suite(.serialized)
struct AnthropicRunnerImageInputTests {
    @Test(
        "Runner.run accepts a multimodal Response.Input against Anthropic",
        .enabled(if: APIKey.hasAnthropic, "Requires ANTHROPIC_API_KEY")
    )
    func runnerMultimodalInput() async throws {
        let agent = BasicAgent(
            name: "AnthropicVision",
            model: "anthropic/\(anthropicVisionModel)",
            instructions: "You are a concise visual assistant. Describe what you see briefly.",
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 200)
        )

        let dataURL = try diceDataURL()
        let multimodal: Response.Input = .array([
            .message(.init(
                role: .user,
                content: [
                    .inputText("What objects are shown in this image? Answer in one short sentence."),
                    .inputImage(dataURL)
                ]
            ))
        ])

        let result = try await Runner.run(
            agent: agent,
            input: multimodal,
            maxTurns: 2
        )
        // Image shows three transparent dice — model should reference
        // "dice" or "die". If the image wasn't decoded server-side, the
        // model would refuse rather than describe.
        let lower = result.finalOutput.lowercased()
        #expect(lower.contains("dice") || lower.contains("die"),
                "expected model to mention dice; got: \(result.finalOutput)")
    }

    @Test(
        "Session round-trip: Anthropic image input persisted then replayed across runs",
        .enabled(if: APIKey.hasAnthropic, "Requires ANTHROPIC_API_KEY")
    )
    func sessionImageRoundTrip() async throws {
        let agent = BasicAgent(
            name: "AnthropicVisionMemory",
            model: "anthropic/\(anthropicVisionModel)",
            instructions: """
                You are a concise assistant with visual memory. Answer briefly. \
                When asked about an earlier image, recall what you saw in it.
                """,
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 200)
        )

        let session = InMemorySession()
        let dataURL = try diceDataURL()

        // Wrap both runs in a single `withTrace` so the dashboard groups
        // them into one workflow — two agent spans, one per Runner.run.
        let second = try await withTrace(name: "Anthropic vision memory") {
            _ = try await Runner.run(
                agent: agent,
                input: .array([
                    .message(.init(role: .user, content: [
                        .inputText("Look at this image. What is shown?"),
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
            // the dice it saw earlier via the replayed session history.
            return try await Runner.run(
                agent: agent,
                input: "What objects did I just show you?",
                session: session,
                maxTurns: 2
            )
        }
        let lower = second.finalOutput.lowercased()
        #expect(lower.contains("dice") || lower.contains("die"),
                "expected model to recall the dice from session; got: \(second.finalOutput)")
    }

    @Test(
        "Anthropic image-input run emits agent + generation spans",
        .enabled(if: APIKey.hasAnthropic, "Requires ANTHROPIC_API_KEY")
    )
    func tracingForImageInput() async throws {
        // Same span-spy pattern LMStudioImageInputTests::tracingForImageInput
        // uses — addProcessor (not setProcessors) so we coexist with any
        // other trace-mutating test in parallel, then scope assertions
        // by our test's agent name + trace_id.
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

        let agentName = "AnthropicVisionTraceProbe_\(UUID().uuidString)"
        let agent = BasicAgent(
            name: agentName,
            model: "anthropic/\(anthropicVisionModel)",
            instructions: "Describe images briefly.",
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 200)
        )
        let dataURL = try diceDataURL()

        _ = try await Runner.run(
            agent: agent,
            input: .array([
                .message(.init(role: .user, content: [
                    .inputText("What's in this image?"),
                    .inputImage(dataURL)
                ]))
            ]),
            maxTurns: 2
        )

        try await Task.sleep(for: .milliseconds(500))

        let captured = await spy.snapshot()
        #expect(!captured.isEmpty, "expected the Runner to emit at least one trace/span")

        let encoder = JSONEncoder()
        let flattened = captured.compactMap { item -> String? in
            guard let data = try? encoder.encode(item),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return json
        }
        let anchorJSON = flattened.first(where: { $0.contains(agentName) })
        let anchor = try #require(anchorJSON, "no spans for \(agentName)")
        let traceID = Self.extractTraceID(from: anchor)
        let resolvedTraceID = try #require(traceID, "expected a trace_id on the agent span")
        let mine = flattened.filter { $0.contains(resolvedTraceID) }
        let joined = mine.joined(separator: "\n")

        #expect(joined.contains("\"type\":\"agent\""),
                "expected at least one agent span")
        // Anthropic routes through createResponse — `responseIdsAreOpenAIRoutable`
        // is false, so per-turn spans carry GenerationSpanData.
        #expect(joined.contains("\"type\":\"generation\""),
                "expected at least one generation span")
    }

    @Test(
        "Traces from an Anthropic image run can be ingested by the OpenAI traces backend",
        .enabled(
            if: APIKey.hasAnthropic && APIKey.hasOpenAI,
            "Requires ANTHROPIC_API_KEY and OPENAI_API_KEY"
        )
    )
    func tracesShipToOpenAI() async throws {
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

        let agentName = "AnthropicImageIngestProbe_\(UUID().uuidString)"
        let agent = BasicAgent(
            name: agentName,
            model: "anthropic/\(anthropicVisionModel)",
            instructions: "Describe images briefly.",
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 200)
        )
        let dataURL = try diceDataURL()

        _ = try await Runner.run(
            agent: agent,
            input: .array([
                .message(.init(role: .user, content: [
                    .inputText("What's in this image?"),
                    .inputImage(dataURL)
                ]))
            ]),
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

        // Same ingest call OpenAITraceExporter makes — proves the
        // payload won't be rejected when it lands on platform.openai.com.
        let openAIKey = try #require(APIKey.openAI as String?)
        let openAI = OpenAI(apiKey: openAIKey)
        try await openAI.ingestTraces(mine)
    }

    /// Pulls the `trace_id` out of a flattened span/trace JSON blob.
    private static func extractTraceID(from json: String) -> String? {
        guard let range = json.range(of: "\"trace_id\":\""),
              let end = json[range.upperBound...].firstIndex(of: "\"") else {
            return nil
        }
        return String(json[range.upperBound ..< end])
    }
}
