import Foundation
@testable import Providers
@testable import Agents
import SwiftMCP
import Testing

@MCPServer
final class Calculator {
    @MCPTool(description: "Adds two integers")
    func add(number1: Int, number2: Int) -> Int {
        number1 + number2
    }
}

struct ResponseTests {
    @Test("Response request encodes phase and prompt-cache fields")
    func responseRequestEncoding() throws {
        let openAI = OpenAI(credential: Credential.bearer("test"))
        let requestBody = ResponseOptionals(
            input: .array([
                .message(.init(role: .assistant, text: "Working", phase: .commentary))
            ]),
            model: "gpt-5.3-codex",
            contextManagement: [.init(compactThreshold: 4096)],
            conversation: nil,
            include: [.reasoningEncryptedContent],
            instructions: nil,
            maxOutputTokens: 512,
            maxToolCalls: 2,
            metadata: ["ticket": "10"],
            parallelToolCalls: false,
            previousResponseId: "resp_prev",
            prompt: .init(
                id: "pmpt_123",
                variables: [
                    "name": .string("Oliver")
                ],
                version: "12"
            ),
            promptCacheKey: "cache-key-1",
            promptCacheRetention: .retention24h,
            reasoning: Reasoning(effort: .minimal, summary: .concise),
            safetyIdentifier: "user-123",
            serviceTier: .auto,
            store: false,
            stream: false,
            temperature: nil,
            text: nil,
            toolChoice: nil,
            tools: nil,
            topP: nil,
            truncation: nil,
            user: nil,
            background: true
        )

        let data = try openAI.encoder.encode(requestBody)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try #require(object["input"] as? [[String: Any]])
        let message = try #require(input.first)
        let prompt = try #require(object["prompt"] as? [String: Any])
        let contextManagement = try #require(object["context_management"] as? [[String: Any]])
        let firstContextManagement = try #require(contextManagement.first)

        #expect(object["max_tool_calls"] as? Int == 2)
        #expect(object["prompt_cache_key"] as? String == "cache-key-1")
        #expect(object["prompt_cache_retention"] as? String == "24h")
        #expect(object["safety_identifier"] as? String == "user-123")
        #expect(message["phase"] as? String == "commentary")
        #expect(prompt["id"] as? String == "pmpt_123")
        #expect((prompt["variables"] as? [String: Any])?["name"] as? String == "Oliver")
        #expect(firstContextManagement["type"] as? String == "compaction")
        #expect(firstContextManagement["compact_threshold"] as? Int == 4096)
    }

    @Test("Response decodes latest parity fields")
    func responseDecodingLatestFields() throws {
        let json = """
        {
          "id": "resp_123",
          "object": "response",
          "created_at": 1741477868,
          "completed_at": 1741477869,
          "background": true,
          "status": "completed",
          "error": null,
          "incomplete_details": null,
          "instructions": null,
          "max_output_tokens": 256,
          "max_tool_calls": 3,
          "model": "gpt-5.3-codex",
          "output": [
            {
              "type": "message",
              "id": "msg_123",
              "role": "assistant",
              "status": "completed",
              "phase": "final_answer",
              "content": [
                {
                  "type": "output_text",
                  "text": "Done",
                  "annotations": []
                }
              ]
            }
          ],
          "output_text": "Done",
          "parallel_tool_calls": true,
          "previous_response_id": "resp_prev",
          "prompt": {
            "id": "pmpt_123",
            "variables": {
              "name": "Oliver"
            },
            "version": "12"
          },
          "prompt_cache_key": "cache-key-1",
          "prompt_cache_retention": "in-memory",
          "reasoning": {
            "effort": "xhigh",
            "summary": "detailed"
          },
          "safety_identifier": "user-123",
          "text": {
            "format": {
              "type": "text"
            }
          },
          "tool_choice": "auto",
          "tools": [],
          "top_p": 1,
          "truncation": "disabled",
          "usage": {
            "input_tokens": 10,
            "input_tokens_details": {
              "cached_tokens": 4
            },
            "output_tokens": 6,
            "output_tokens_details": {
              "reasoning_tokens": 2
            },
            "total_tokens": 16
          },
          "conversation": {
            "id": "conv_123"
          },
          "service_tier": "auto"
        }
        """

        let response = try OpenAI(credential: Credential.bearer("test"))
            .decoder.decode(Response.self, from: Data(json.utf8))
        let message = try #require(response.output.first)

        #expect(response.completedAt != nil)
        #expect(response.background == true)
        #expect(response.maxToolCalls == 3)
        #expect(response.outputText == "Done")
        #expect(response.conversation?.id == "conv_123")
        #expect(response.prompt?.id == "pmpt_123")
        #expect(response.promptCacheKey == "cache-key-1")
        #expect(response.promptCacheRetention == .inMemory)
        #expect(response.safetyIdentifier == "user-123")
        #expect(response.reasoning?.effort == .xhigh)

        guard case let .message(output) = message else {
            Issue.record("Expected message output")
            return
        }

        #expect(output.phase == .finalAnswer)
    }

    @Test("ReasoningOutput prefers non-empty `content` over empty `summary` array")
    func reasoningOutputFallsThroughEmptySummary() throws {
        // LM Studio's `/v1/responses` returns reasoning items with BOTH
        // `summary: []` (empty) AND the rich text in
        // `content: [{type: "reasoning_text", text: "..."}]`. The
        // decoder used to take the summary branch on an empty array and
        // never look at content, leaving the reasoning span empty on
        // the trace dashboard. Guard against that.
        let json = """
        {
          "id": "rs_abc",
          "type": "reasoning",
          "status": "completed",
          "summary": [],
          "content": [
            {"type": "reasoning_text", "text": "let me think about this"}
          ]
        }
        """
        let output = try OpenAI(credential: Credential.bearer("test")).decoder.decode(
            OutputItem.ReasoningOutput.self, from: Data(json.utf8)
        )
        #expect(output.summary.count == 1)
        #expect(output.summary.first?.text == "let me think about this")
    }

    @Test("Reasoning text decodes encrypted content include")
    func reasoningTextEncryptedContentDecoding() throws {
        let json = """
        {
          "type": "reasoning_text",
          "text": "hidden",
          "encrypted_content": "ciphertext"
        }
        """

        let item = try OpenAI(credential: Credential.bearer("test"))
            .decoder.decode(ContentItem.self, from: Data(json.utf8))

        guard case let .reasoningText(reasoning) = item else {
            Issue.record("Expected reasoning text content")
            return
        }

        #expect(reasoning.text == "hidden")
        #expect(reasoning.encryptedContent == "ciphertext")
    }

    @Test("Response input replay preserves assistant phase")
    func responseInputReplayPreservesAssistantPhase() {
        let input = Response.Input.array([
            .message(.init(role: .assistant, text: "Thinking out loud", phase: .commentary)),
            .message(.init(role: .assistant, text: "Final answer", phase: .finalAnswer)),
            .message(.init(role: .user, text: "Thanks"))
        ])

        let messages = input.toChatMessage()

        #expect(messages.count == 3)
        #expect(messages[0].role == .assistant)
        #expect(messages[0].phase == .commentary)
        #expect(messages[0].textContent == "Thinking out loud")
        #expect(messages[1].role == .assistant)
        #expect(messages[1].phase == .finalAnswer)
        #expect(messages[1].textContent == "Final answer")
        #expect(messages[2].role == .user)
        #expect(messages[2].phase == nil)
    }

    @Test("Response input replay remains backward compatible without phase")
    func responseInputReplayBackwardCompatibleWithoutPhase() {
        let input = Response.Input.array([
            .message(.init(role: .assistant, text: "Legacy assistant")),
            .message(.init(role: .system, text: "System")),
            .message(.init(role: .developer, text: "Developer"))
        ])

        let messages = input.toChatMessage()

        #expect(messages.count == 3)
        #expect(messages[0].role == .assistant)
        #expect(messages[0].phase == nil)
        #expect(messages[1].role == .system)
        #expect(messages[2].role == .developer)
    }

    @Test("Response decodes include-rich file search and web search payloads")
    func responseDecodesRichIncludePayloads() throws {
        let json = """
        {
          "id": "resp_456",
          "object": "response",
          "created_at": 1741477868,
          "status": "completed",
          "error": null,
          "incomplete_details": null,
          "instructions": null,
          "max_output_tokens": 256,
          "model": "gpt-5.4",
          "output": [
            {
              "type": "file_search_call",
              "id": "fs_123",
              "queries": ["AgentCorp"],
              "status": "completed",
              "results": [
                {
                  "attributes": {
                    "source": "docs",
                    "rank": 1,
                    "trusted": true
                  },
                  "file_id": "file_123",
                  "filename": "notes.md",
                  "score": 0.93,
                  "text": "Matched text"
                }
              ]
            },
            {
              "type": "web_search_call",
              "id": "ws_123",
              "status": "searching",
              "action": {
                "type": "search",
                "queries": ["AgentCorp latest"],
                "sources": [
                  {
                    "type": "url",
                    "url": "https://example.com/article"
                  }
                ]
              }
            },
            {
              "type": "message",
              "id": "msg_123",
              "role": "assistant",
              "status": "completed",
              "content": [
                {
                  "type": "output_text",
                  "text": "Done",
                  "annotations": [],
                  "logprobs": [
                    {
                      "token": "Done",
                      "bytes": [68, 111, 110, 101],
                      "logprob": -0.1,
                      "top_logprobs": [
                        {
                          "token": "Done",
                          "bytes": [68, 111, 110, 101],
                          "logprob": -0.1
                        }
                      ]
                    }
                  ]
                }
              ]
            }
          ],
          "parallel_tool_calls": true,
          "text": {
            "format": {
              "type": "text"
            }
          },
          "tool_choice": "auto",
          "tools": [],
          "top_p": 1,
          "truncation": "disabled"
        }
        """

        let response = try OpenAI(credential: Credential.bearer("test"))
            .decoder.decode(Response.self, from: Data(json.utf8))
        #expect(response.output.count == 3)

        guard case let .fileSearch(fileSearch) = response.output[0] else {
            Issue.record("Expected file search output")
            return
        }

        #expect(fileSearch.status == .completed)
        #expect(fileSearch.results?.first?.fileId == "file_123")
        #expect(fileSearch.results?.first?.filename == "notes.md")
        #expect(fileSearch.results?.first?.score == 0.93)

        guard case let .webSearch(webSearch) = response.output[1] else {
            Issue.record("Expected web search output")
            return
        }

        #expect(webSearch.status == .searching)
        guard case let .search(searchAction) = webSearch.action else {
            Issue.record("Expected search web action")
            return
        }

        #expect(searchAction.queries == ["AgentCorp latest"])
        #expect(searchAction.sources?.first?.url.absoluteString == "https://example.com/article")

        guard case let .message(message) = response.output[2] else {
            Issue.record("Expected message output")
            return
        }

        guard case let .outputText(outputText) = try #require(message.content.first) else {
            Issue.record("Expected output text content")
            return
        }

        #expect(outputText.logprobs?.first?.token == "Done")
        #expect(outputText.logprobs?.first?.topLogprobs.first?.token == "Done")
    }

    @Test("Streaming response completes", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func responseStream() async throws {
        let openAI = try TestClients.openAI()
        let stream = try await openAI.createResponseStream(input: .text("Tell me a short joke"), model: "gpt-4.1-mini")

        var finalResponse: Response?
        var events = [ResponsesStreamEvent]()
        for try await event in stream {
            events.append(event)
            if case let .responseCompleted(response) = event.object {
                finalResponse = response
            }
        }

        #expect(!events.isEmpty)
        let response = try #require(finalResponse)
        #expect(response.status == .completed)
        #expect(!response.output.isEmpty)
    }

    @Test("Response with tool choice", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func responseWithTool() async throws {
        let openAI = try TestClients.openAI()
        let tools = await calculatorTools()

        let response = try await openAI.createResponse(
            input: .text("What is 42 + 58?"),
            model: "gpt-4.1-mini",
            toolChoice: .auto,
            tools: tools
        )

        let functionCallOutput = try #require(response.output.first { output in
            if case .functionCall = output { return true }
            return false
        })

        guard case let .functionCall(call) = functionCallOutput else {
            Issue.record("Expected function call output")
            return
        }

        let data = Data(call.arguments.utf8)
        let args = try #require(JSONSerialization.jsonObject(with: data) as? [String: Double])
        let result = Calculator().add(number1: Int(args["number1"] ?? 0), number2: Int(args["number2"] ?? 0))

        let functionCallOutputResult = FunctionCallOutput(callId: call.callId, output: String(result))
        let followUp = try await openAI.createResponse(
            input: .array([.functionCallOutput(functionCallOutputResult)]),
            model: "gpt-4.1-mini",
            previousResponseId: response.id,
            toolChoice: .auto,
            tools: tools
        )

        let messageOutput = try #require(followUp.output.first {
            if case .message = $0 { return true }
            return false
        })

        guard case let .message(message) = messageOutput else {
            Issue.record("Expected message output")
            return
        }

        let textContent = try #require(message.content.first {
            if case .outputText = $0 { return true }
            return false
        })

        if case let .outputText(content) = textContent {
            #expect(content.text.contains("100"))
        }
    }

    @Test("Image input response", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
    func responseWithImageInput() async throws {
        let openAI = try TestClients.openAI()
        let data = try VisionImageTestHelpers.visionFixtureData()
        let dataURL = VisionImageTestHelpers.responseDataURL(for: data, mimeType: "image/png")

        let response = try await openAI.createResponse(
            input: .array([
                .message(.init(
                    role: "user",
                    content: [
                        .inputText("what is in this image?"),
                        .inputImage(dataURL)
                    ]
                ))
            ]),
            model: "gpt-4.1"
        )

        #expect(response.status == .completed)
        let messageOutput = try #require(response.output.first {
            if case .message = $0 { return true }
            return false
        })

        if case let .message(message) = messageOutput {
            let textContent = try #require(message.content.first {
                if case .outputText = $0 { return true }
                return false
            })

            if case let .outputText(content) = textContent {
                #expect(!content.text.isEmpty)
            }
        }
    }

    // MARK: - Helpers

    private func calculatorTools() async -> [Tool] {
        await Calculator().toolDescriptions.compactMap { description in
            guard let function = description.function else { return nil }
            return .function(FunctionTool(
                name: function.name,
                description: function.description,
                parameters: function.parameters,
                strict: false
            ))
        }
    }
}
