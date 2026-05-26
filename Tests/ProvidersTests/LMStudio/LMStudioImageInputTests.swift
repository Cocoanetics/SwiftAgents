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

        // Follow-up turn (plain text) — the model should reference the
        // colour it saw earlier via the replayed session history.
        let second = try await Runner.run(
            agent: agent,
            input: "What colour was the image I just showed you?",
            session: session,
            maxTurns: 2
        )
        #expect(second.finalOutput.lowercased().contains("red"))
    }
}
