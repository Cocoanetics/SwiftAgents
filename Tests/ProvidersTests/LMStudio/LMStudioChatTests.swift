//
//  LMStudioChatTests.swift
//  ProvidersTests
//
//  Offline tests for the LM Studio provider: wire-shape encoding/decoding,
//  conversation-state policy, and the synthetic-id sentinel that protects
//  the next turn from sending back an unstored response id.
//

import Foundation
@testable import Providers
import Testing

struct LMStudioChatTests {
    // MARK: - Decoding

    @Test("Decodes the documented LM Studio response shape into a Response")
    func decodesSimpleMessageResponse() throws {
        let json = Data("""
        {
            "model_instance_id": "ibm/granite-4-micro",
            "model": "ibm/granite-4-micro",
            "output": [
                {"type": "message", "id": "msg_1", "content": "That's great! Blue is a beautiful color."}
            ],
            "response_id": "resp_abc123xyz"
        }
        """.utf8)

        let lmstudio = LMStudio()
        let decoded: LMStudioChatResponse = try lmstudio.decoder.decode(LMStudioChatResponse.self, from: json)

        #expect(decoded.responseId == "resp_abc123xyz")
        #expect(decoded.modelInstanceId == "ibm/granite-4-micro")
        #expect(decoded.output.count == 1)

        let response = decoded.toResponse(modelHint: "ibm/granite-4-micro", instructions: nil)
        #expect(response.id == "resp_abc123xyz")
        #expect(response.model == "ibm/granite-4-micro")
        #expect(response.output.count == 1)

        guard case let .message(messageOutput) = response.output.first else {
            Issue.record("Expected message output, got \(String(describing: response.output.first))")
            return
        }
        guard case let .outputText(text) = messageOutput.content.first else {
            Issue.record("Expected outputText content")
            return
        }
        #expect(text.text == "That's great! Blue is a beautiful color.")
    }

    @Test("Falls back to OpenAI-shaped output when content is structured")
    func decodesStructuredMessageResponse() throws {
        let json = Data("""
        {
            "model_instance_id": "qwen3-coder",
            "output": [
                {
                    "type": "message",
                    "id": "msg_2",
                    "role": "assistant",
                    "status": "completed",
                    "content": [
                        {"type": "output_text", "text": "Hi there.", "annotations": []}
                    ]
                }
            ],
            "response_id": "resp_xyz"
        }
        """.utf8)

        let lmstudio = LMStudio()
        let decoded = try lmstudio.decoder.decode(LMStudioChatResponse.self, from: json)
        let response = decoded.toResponse(modelHint: "qwen3-coder", instructions: nil)

        guard case let .message(messageOutput) = response.output.first else {
            Issue.record("Expected message output")
            return
        }
        guard case let .outputText(text) = messageOutput.content.first else {
            Issue.record("Expected outputText content")
            return
        }
        #expect(text.text == "Hi there.")
    }

    @Test("Missing response_id (store: false) produces a sentinel id")
    func sentinelIdWhenResponseIdMissing() throws {
        let json = Data("""
        {
            "model_instance_id": "ibm/granite-4-micro",
            "output": [
                {"type": "message", "content": "One-off response, not stored."}
            ]
        }
        """.utf8)

        let lmstudio = LMStudio()
        let decoded = try lmstudio.decoder.decode(LMStudioChatResponse.self, from: json)
        let response = decoded.toResponse(modelHint: "ibm/granite-4-micro", instructions: nil)

        #expect(response.id.hasPrefix(LMStudio.statelessIdPrefix))
    }

    // MARK: - Encoding

    @Test("Request encodes only the current turn; previous_response_id chains")
    func requestEncodesPreviousResponseId() throws {
        let lmstudio = LMStudio()
        let request = LMStudioChatRequest(
            model: "ibm/granite-4-micro",
            input: .text("What color did I just mention?"),
            previousResponseId: "resp_abc123",
            store: nil,
            instructions: nil,
            tools: nil,
            toolChoice: nil,
            temperature: nil,
            topP: nil,
            maxOutputTokens: nil,
            metadata: nil
        )

        let data = try lmstudio.encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["model"] as? String == "ibm/granite-4-micro")
        #expect(json?["input"] as? String == "What color did I just mention?")
        #expect(json?["previous_response_id"] as? String == "resp_abc123")
        // Nil fields must not appear on the wire.
        #expect(json?["store"] == nil)
        #expect(json?["tools"] == nil)
        #expect(json?["instructions"] == nil)
    }

    @Test("Request includes store: false when caller opts out of server history")
    func requestEncodesStoreFalse() throws {
        let lmstudio = LMStudio()
        let request = LMStudioChatRequest(
            model: "ibm/granite-4-micro",
            input: .text("Tell me a joke."),
            previousResponseId: nil,
            store: false,
            instructions: nil,
            tools: nil,
            toolChoice: nil,
            temperature: nil,
            topP: nil,
            maxOutputTokens: nil,
            metadata: nil
        )

        let data = try lmstudio.encoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["store"] as? Bool == false)
    }

    // MARK: - Policy

    @Test("LM Studio declares lmStudioNative state policy")
    func policyIsLMStudioNative() {
        let lmstudio = LMStudio()
        #expect(lmstudio.statePolicy.supportsServerSideHistory == true)
        #expect(lmstudio.statePolicy.responseIdsAreOpenAIRoutable == false)
    }

    @Test("OpenAI declares openAIResponses state policy")
    func policyIsOpenAIResponses() {
        let openAI = OpenAI(apiKey: "test")
        #expect(openAI.statePolicy.supportsServerSideHistory == true)
        #expect(openAI.statePolicy.responseIdsAreOpenAIRoutable == true)
    }

    @Test("Other providers default to stateless policy")
    func defaultPolicyIsStateless() {
        let anthropic = Anthropic(apiKey: "test")
        #expect(anthropic.statePolicy.supportsServerSideHistory == false)
        #expect(anthropic.statePolicy.responseIdsAreOpenAIRoutable == false)
    }

    // MARK: - Providers registry

    @Test("Providers registry returns an LMStudio instance for the lmstudio name")
    func providersReturnsLMStudio() async throws {
        let providers = Providers()
        let api = try await providers.api(for: "lmstudio/ibm/granite-4-micro")
        #expect(api is LMStudio)
    }
}
