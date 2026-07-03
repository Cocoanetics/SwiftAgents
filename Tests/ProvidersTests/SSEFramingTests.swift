//
//  SSEFramingTests.swift
//  SwiftAgents
//
//  Offline tests for the shared SSE framing (`SSEDataSequence`) and the
//  provider stream-parse loops built on top of it — canned transcripts only,
//  no network, no API keys.
//

import Foundation
@testable import Providers
import Testing

// MARK: - Canned sources

/// A byte stream that delivers `text` and then finishes — optionally with an
/// error, modeling a connection drop mid-stream.
private func byteStream(_ text: String, throwing error: Error? = nil) -> AsyncThrowingStream<UInt8, Error> {
    AsyncThrowingStream { continuation in
        for byte in Array(text.utf8) {
            continuation.yield(byte)
        }
        continuation.finish(throwing: error)
    }
}

private func lineStream(_ lines: [String]) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        for line in lines {
            continuation.yield(line)
        }
        continuation.finish()
    }
}

private struct StreamDropped: Error {}

// MARK: - Fixtures

private func chunkJSON(_ content: String) -> String {
    #"{"id":"c1","object":"chat.completion.chunk","created":1,"model":"m","#
        + #""choices":[{"index":0,"delta":{"content":"\#(content)"},"finish_reason":null}]}"#
}

private func outputTextDeltaJSON(_ delta: String) -> String {
    #"{"type":"response.output_text.delta","item_id":"i1","#
        + #""output_index":0,"content_index":0,"delta":"\#(delta)"}"#
}

@Suite("SSE framing")
struct SSEFramingTests {
    // MARK: - SSEDataSequence

    @Test("joins multi-line data, skips comments and non-data fields, tolerates CRLF")
    func dataSequenceFraming() async throws {
        let wire = ": keep-alive\n"
            + "event: message\r\n"
            + "data: line1\n"
            + "data: line2\n"
            + "\r\n"
            + "id: 42\n"
            + "data: single\n"
            + "\n"

        var payloads: [String] = []
        for try await payload in SSEDataSequence(bytes: byteStream(wire)) {
            payloads.append(String(bytes: payload, encoding: .utf8) ?? "<binary>")
        }

        #expect(payloads == ["line1\nline2", "single"])
    }

    @Test("a byte-stream error propagates after the payloads before it")
    func dataSequencePropagatesError() async {
        let sequence = SSEDataSequence(bytes: byteStream("data: a\n\n", throwing: StreamDropped()))

        var payloads: [String] = []
        do {
            for try await payload in sequence {
                payloads.append(String(bytes: payload, encoding: .utf8) ?? "<binary>")
            }
            Issue.record("expected StreamDropped")
        } catch {
            #expect(error is StreamDropped)
        }

        #expect(payloads == ["a"])
    }

    // MARK: - Chat-completions chunk stream

    @Test("chunks decode in order, proxy comments are tolerated, [DONE] ends the stream")
    func chunkStreamDecodesAndFinishesOnDone() async throws {
        let wire = "data: \(chunkJSON("Hel"))\n\n"
            + ": OPENROUTER PROCESSING\n\n"
            + "data: \(chunkJSON("lo"))\n\n"
            + "data: [DONE]\n\n"
            + "data: \(chunkJSON("after done"))\n\n"

        var contents: [String] = []
        for try await chunk in API().chunkStream(from: byteStream(wire)) {
            contents.append(chunk.choices.first?.delta.content ?? "")
        }

        #expect(contents == ["Hel", "lo"])
    }

    @Test("a stream that ends without [DONE] still finishes")
    func chunkStreamFinishesOnNaturalEnd() async throws {
        var contents: [String] = []
        for try await chunk in API().chunkStream(from: byteStream("data: \(chunkJSON("solo"))\n\n")) {
            contents.append(chunk.choices.first?.delta.content ?? "")
        }

        #expect(contents == ["solo"])
    }

    @Test("a mid-stream transport error reaches the consumer")
    func chunkStreamPropagatesTransportError() async {
        let wire = "data: \(chunkJSON("x"))\n\n"

        var received = 0
        do {
            for try await _ in API().chunkStream(from: byteStream(wire, throwing: StreamDropped())) {
                received += 1
            }
            Issue.record("expected StreamDropped")
        } catch {
            #expect(error is StreamDropped)
        }

        #expect(received == 1)
    }

    @Test("a malformed chunk finishes the stream with the decode error")
    func chunkStreamPropagatesDecodeError() async {
        do {
            for try await _ in API().chunkStream(from: byteStream("data: {not json}\n\n")) {}
            Issue.record("expected a DecodingError")
        } catch {
            #expect(error is DecodingError)
        }
    }

    // MARK: - Responses event stream

    @Test("payload-typed events yield in order, unknown types are skipped, [DONE] ends the stream")
    func responsesStreamDispatchesOnPayloadType() async throws {
        let openAI = OpenAI(credential: Credential.bearer("offline-test"))
        let wire = "data: \(outputTextDeltaJSON("Hel"))\n\n"
            + "data: {\"type\":\"response.some_future_event\",\"payload\":true}\n\n"
            + "data: {\"type\":\"response.apply_patch_call.delta\"}\n\n"
            + "data: \(outputTextDeltaJSON("lo"))\n\n"
            + "data: [DONE]\n\n"
            + "data: \(outputTextDeltaJSON("after done"))\n\n"

        var deltas: [String] = []
        for try await event in openAI.responsesEventStream(from: byteStream(wire)) {
            guard case let .outputTextDelta(info) = event.object else {
                Issue.record("unexpected event '\(event.type)'")
                continue
            }
            deltas.append(info.delta)
        }

        #expect(deltas == ["Hel", "lo"])
    }

    @Test("a typeless LM Studio error payload maps to an error event")
    func responsesStreamLMStudioErrorFallback() async throws {
        let openAI = OpenAI(credential: Credential.bearer("offline-test"))
        let wire = "data: {\"error\":{\"message\":\"model crashed\",\"type\":\"server_error\"}}\n\n"
            + "data: [DONE]\n\n"

        var messages: [String] = []
        for try await event in openAI.responsesEventStream(from: byteStream(wire)) {
            guard case let .error(detail) = event.object else {
                Issue.record("unexpected event '\(event.type)'")
                continue
            }
            #expect(event.type == "error")
            messages.append(detail.message)
        }

        #expect(messages == ["model crashed"])
    }

    @Test("a malformed payload for a recognized type finishes the stream with the decode error")
    func responsesStreamPropagatesDecodeError() async {
        let openAI = OpenAI(credential: Credential.bearer("offline-test"))
        let wire = "data: {\"type\":\"response.output_text.delta\",\"delta\":42}\n\n"

        do {
            for try await _ in openAI.responsesEventStream(from: byteStream(wire)) {}
            Issue.record("expected a DecodingError")
        } catch {
            #expect(error is DecodingError)
        }
    }

    @Test("a mid-stream transport error reaches the Responses consumer")
    func responsesStreamPropagatesTransportError() async {
        let openAI = OpenAI(credential: Credential.bearer("offline-test"))
        let wire = "data: \(outputTextDeltaJSON("x"))\n\n"

        var received = 0
        do {
            for try await _ in openAI.responsesEventStream(from: byteStream(wire, throwing: StreamDropped())) {
                received += 1
            }
            Issue.record("expected StreamDropped")
        } catch {
            #expect(error is StreamDropped)
        }

        #expect(received == 1)
    }

    // MARK: - Anthropic event stream

    @Test("dispatches on the payload's type field, including bare ping/message_stop")
    func anthropicStreamDispatchesOnPayloadType() async throws {
        let anthropic = Anthropic(credential: Credential.apiKey("offline-test"))
        let wire = "data: {\"type\":\"content_block_delta\",\"index\":0,"
            + "\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}\n\n"
            + "data: {\"type\":\"ping\"}\n\n"
            + "data: {\"type\":\"shiny_new_event\"}\n\n"
            + "data: {\"type\":\"message_stop\"}\n\n"

        var kinds: [String] = []
        for try await event in anthropic.anthropicEventStream(from: byteStream(wire)) {
            switch event {
                case let .contentBlockDelta(delta):
                    if case let .textDelta(text) = delta.delta {
                        kinds.append("text:\(text)")
                    }
                case .ping:
                    kinds.append("ping")
                case let .unknown(type):
                    kinds.append("unknown:\(type)")
                case .messageStop:
                    kinds.append("stop")
                default:
                    Issue.record("unexpected event \(event)")
            }
        }

        #expect(kinds == ["text:Hi", "ping", "unknown:shiny_new_event", "stop"])
    }

    @Test("a payload without the type discriminator finishes the Anthropic stream with a decode error")
    func anthropicStreamRejectsTypelessPayload() async {
        let anthropic = Anthropic(credential: Credential.apiKey("offline-test"))

        do {
            for try await _ in anthropic.anthropicEventStream(from: byteStream("data: {\"whatever\":1}\n\n")) {}
            Issue.record("expected a DecodingError")
        } catch {
            #expect(error is DecodingError)
        }
    }

    // MARK: - Assistants event stream

    @Test("pairs event:/data: lines, tolerates non-data lines, [DONE] ends the stream")
    func assistantStreamDispatchesOnEventName() async throws {
        let openAI = OpenAI(credential: Credential.bearer("offline-test"))
        let lines = [
            ": comment",
            "",
            "event: error",
            "data: {\"message\":\"boom\",\"type\":\"server_error\"}",
            "",
            "event: fancy.new.event",
            "data: {}",
            "",
            "data: [DONE]",
            "event: error",
            "data: {\"message\":\"after done\",\"type\":\"server_error\"}"
        ]

        var messages: [String] = []
        for try await event in openAI.assistantEventStream(from: lineStream(lines)) {
            guard case let .error(detail) = event.object else {
                Issue.record("unexpected event '\(event.type)'")
                continue
            }
            #expect(event.type == "error")
            messages.append(detail.message)
        }

        #expect(messages == ["boom"])
    }

    @Test("an Assistants stream that ends without [DONE] still finishes")
    func assistantStreamFinishesOnNaturalEnd() async throws {
        let openAI = OpenAI(credential: Credential.bearer("offline-test"))
        let lines = [
            "event: error",
            "data: {\"message\":\"m\",\"type\":\"t\"}"
        ]

        var count = 0
        for try await _ in openAI.assistantEventStream(from: lineStream(lines)) {
            count += 1
        }

        #expect(count == 1)
    }

    @Test("a malformed Assistants payload finishes the stream with the decode error")
    func assistantStreamPropagatesDecodeError() async {
        let openAI = OpenAI(credential: Credential.bearer("offline-test"))
        let lines = [
            "event: error",
            "data: {\"message\":42}"
        ]

        do {
            for try await _ in openAI.assistantEventStream(from: lineStream(lines)) {}
            Issue.record("expected a DecodingError")
        } catch {
            #expect(error is DecodingError)
        }
    }
}
