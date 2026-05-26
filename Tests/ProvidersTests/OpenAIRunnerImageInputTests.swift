//
//  OpenAIRunnerImageInputTests.swift
//  ProvidersTests
//
//  Image-input coverage via the Agents SDK Runner against OpenAI.
//  Mirrors the LM Studio / Anthropic / Gemini equivalents so the
//  capability matrix (chat, tools, structured output, image input,
//  session round-trip) is symmetric across providers.
//
//  Gated on OPENAI_API_KEY.
//

import Foundation
@testable import Providers
import Testing

private let openAIVisionModel = "gpt-4.1"

private func diceDataURL() throws -> URL {
    let bundleURL = try #require(
        Bundle.module.url(forResource: "vision-test", withExtension: "png"),
        "vision-test fixture is required"
    )
    let data = try Data(contentsOf: bundleURL)
    let dataURL = "data:image/png;base64,\(data.base64EncodedString())"
    return try #require(URL(string: dataURL), "expected a valid data: URL")
}

struct OpenAIRunnerImageInputTests {
    @Test(
        "Runner.run accepts a multimodal Response.Input against OpenAI",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func runnerMultimodalInput() async throws {
        let agent = BasicAgent(
            name: "OpenAIVision",
            model: openAIVisionModel,
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
        let lower = result.finalOutput.lowercased()
        #expect(lower.contains("dice") || lower.contains("die"),
                "expected model to mention dice; got: \(result.finalOutput)")
    }

    @Test(
        "Session round-trip: OpenAI image input persisted then replayed across runs",
        .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY")
    )
    func sessionImageRoundTrip() async throws {
        let agent = BasicAgent(
            name: "OpenAIVisionMemory",
            model: openAIVisionModel,
            instructions: """
                You are a concise assistant with visual memory. Answer briefly. \
                When asked about an earlier image, recall what you saw in it.
                """,
            modelSettings: ModelSettings(temperature: 0, maxCompletionTokens: 200)
        )

        let session = InMemorySession()
        let dataURL = try diceDataURL()

        let second = try await withTrace(name: "OpenAI vision memory") {
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
}
