//
//  LMStudioResponsesRoutingLiveTests.swift
//  ProvidersTests
//
//  Live tests pinning the LM Studio streaming gate:
//   - a `.text` turn streams via `/v1/responses` (Responses streaming),
//   - a structured-output (`@Schema`) turn falls back to
//     `/v1/chat/completions` (where `response_format` is honored) and decodes.
//
//  Routing is proven by a `createUrlRequest`-recording `LMStudio` subclass,
//  since both streaming paths emit identical normalized events.
//
//  Gated on LMSTUDIO_URL; model from LMSTUDIO_MODEL (default qwen3-4b-mlx).
//

import Foundation
import SwiftCross
@testable import Agents
@testable import Providers
import SwiftMCP
import Testing

private let lmURL = ProcessInfo.processInfo.environment["LMSTUDIO_URL"] ?? "http://localhost:1234"
private let lmModel = ProcessInfo.processInfo.environment["LMSTUDIO_MODEL"] ?? "qwen3-4b-mlx"

private final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func record(_ path: String) { lock.lock(); storage.append(path); lock.unlock() }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class RecordingLMStudio: LMStudio, @unchecked Sendable {
    let recorder = PathRecorder()
    override func createUrlRequest(
        httpMethod: String = "GET",
        path: String,
        body: Codable? = nil,
        queryItems: [URLQueryItem]? = nil
    ) throws -> URLRequest {
        recorder.record(path)
        return try super.createUrlRequest(httpMethod: httpMethod, path: path, body: body, queryItems: queryItems)
    }
}

@Schema
private struct ColourGuess: Codable, Equatable {
    let colour: String
    let confidence: Double
}

private final class ColourAgent: Agent {
    typealias OutputType = ColourGuess
    let name = "ColourGuesser"
    let model: String? = nil
    let instructions = "Decide what colour a thing usually is. Answer concisely."
    let modelSettings = ModelSettings(temperature: 0)
}

struct LMStudioResponsesRoutingLiveTests {
    private static let hasLMStudio = ProcessInfo.processInfo.environment["LMSTUDIO_URL"] != nil

    @Test(
        "LM Studio: text streamed run routes through /v1/responses",
        .enabled(if: hasLMStudio, "Requires LMSTUDIO_URL")
    )
    func textStreamsViaResponses() async throws {
        let api = RecordingLMStudio(endpointURL: try #require(URL(string: lmURL)))
        let agent = BasicAgent(
            name: "Streamer",
            model: lmModel,
            instructions: "You are concise. Reply in one short sentence.",
            modelSettings: ModelSettings(temperature: 0)
        )
        let result = Runner.runStreamed(
            agent: agent,
            input: "Why is the sky blue? One sentence.",
            config: RunConfig(model: lmModel, api: api)
        )

        var deltas = 0
        var text = ""
        for try await event in result.events {
            if case let .rawResponseEvent(raw) = event, case let .outputTextDelta(info) = raw.object {
                deltas += 1
                text += info.delta
            }
        }

        let paths = api.recorder.paths
        #expect(paths.contains("/v1/responses"), "expected Responses path; recorded \(paths)")
        #expect(!paths.contains("/v1/chat/completions"), "should not have hit chat completions; recorded \(paths)")
        #expect(deltas > 1, "expected multiple streamed text deltas, got \(deltas)")
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "got: \(text)")
    }

    @Test(
        "LM Studio: structured-output streamed run falls back to /v1/chat/completions and decodes",
        .enabled(if: hasLMStudio, "Requires LMSTUDIO_URL")
    )
    func structuredStreamsViaChatCompletions() async throws {
        let api = RecordingLMStudio(endpointURL: try #require(URL(string: lmURL)))
        let result = Runner.runStreamed(
            agent: ColourAgent(),
            input: "What colour is grass?",
            config: RunConfig(model: lmModel, api: api)
        )

        var message = ""
        for try await event in result.events {
            if case let .runItemEvent(_, item) = event, case let .message(text) = item, !text.isEmpty {
                message = text
            }
        }

        let paths = api.recorder.paths
        #expect(paths.contains("/v1/chat/completions"), "expected chat-completions fallback; recorded \(paths)")
        #expect(!paths.contains("/v1/responses"), "structured output must not use Responses; recorded \(paths)")

        let decoded = try JSONDecoder().decode(ColourGuess.self, from: Data(message.utf8))
        #expect(!decoded.colour.isEmpty, "decoded colour was empty; raw message: \(message)")
        #expect(decoded.confidence.isFinite)
    }
}
