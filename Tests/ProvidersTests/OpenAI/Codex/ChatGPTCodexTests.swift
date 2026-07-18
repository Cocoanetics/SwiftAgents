//
//  ChatGPTCodexTests.swift
//  ProvidersTests
//
//  Offline coverage for the ChatGPT-subscription Codex backend client:
//  the `ChatGPTCodexAuthorization` headers, the `/v1` → `/` path rewrite
//  (…/backend-api/codex/responses), the dropped `OpenAI-Beta` header, and
//  the streamed Runner's stateless mode — full accumulated input every
//  turn, `instructions` always present, `store: false` forced, and no
//  `previous_response_id` chaining.
//
//  No live network: a `URLProtocol` stub records every request and feeds
//  back scripted SSE bodies. Serialized because the stub's request log and
//  response script are process-global.
//

import Foundation
@testable import Agents
@testable import Providers
import SwiftMCP
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Request-recording SSE stub

/// Intercepts every request on a stubbed `URLSession`, records it (with its
/// body), and replays the next scripted SSE payload.
private final class CodexBackendStub: URLProtocol {
    struct RecordedRequest {
        let request: URLRequest
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordedRequests: [RecordedRequest] = []
    nonisolated(unsafe) private static var scriptedResponses: [Data] = []

    /// Clears the request log and scripts the SSE bodies to replay, in order.
    static func script(_ responses: [Data]) {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests = []
        scriptedResponses = responses
    }

    static var recorded: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    private static func record(_ request: RecordedRequest) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
        guard !scriptedResponses.isEmpty else { return nil }
        return scriptedResponses.removeFirst()
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(from: request)
        guard let url = request.url,
              let payload = Self.record(RecordedRequest(request: request, body: body))
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands the POST body to a `URLProtocol` as a stream, not
    /// `httpBody` — drain whichever is set.
    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 16384
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - SSE fixtures

private enum CodexFixture {
    /// Frames JSON event payloads as an SSE byte stream.
    static func sse(_ events: [String]) -> Data {
        Data((events.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n").utf8)
    }

    static func outputItemDone(_ item: String) -> String {
        #"{"type":"response.output_item.done","output_index":0,"item":\#(item)}"#
    }

    /// The live codex backend sends `response.completed` with an EMPTY
    /// `output` array — items arrive only via `response.output_item.done`.
    /// The default mirrors that; the stateful (api.openai.com) fixture
    /// passes explicit items, matching the first-party behavior.
    static func responseCompleted(id: String, outputItems: [String] = []) -> String {
        let response = #"{"id":"\#(id)","object":"response","created_at":1700000000,"#
            + #""status":"completed","model":"gpt-5.3-codex","#
            + #""output":[\#(outputItems.joined(separator: ","))],"parallel_tool_calls":true,"#
            + #""text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[]}"#
        return #"{"type":"response.completed","response":\#(response)}"#
    }

    static let reasoningItem = #"{"type":"reasoning","id":"rs_1","#
        + #""summary":[{"type":"summary_text","text":"Checking the weather tool"}],"#
        + #""encrypted_content":"ENCRYPTED_BLOB"}"#

    static let functionCallItem = #"{"type":"function_call","id":"fc_1","call_id":"call_1","#
        + #""name":"get_weather","arguments":"{\"city\": \"Berlin\"}","status":"completed"}"#

    static func messageItem(_ text: String) -> String {
        #"{"type":"message","id":"msg_1","role":"assistant","status":"completed","#
            + #""content":[{"type":"output_text","text":"\#(text)","annotations":[]}]}"#
    }
}

// MARK: - Test tool

@MCPServer
private final class CodexWeatherTools {
    @MCPTool(description: "Returns the current weather for a city")
    func get_weather(city: String) -> String {
        "It is 18°C and partly cloudy in \(city)."
    }
}

// MARK: - Tests

@Suite(.serialized)
struct ChatGPTCodexTests {
    private static let instructions = "You are a codex test agent."

    private func attachStub(to api: API) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CodexBackendStub.self]
        let stubbed = URLSession(configuration: configuration)
        api.session = stubbed
        api.streamSession = stubbed
    }

    private func makeStubbedCodex(accountID: String? = "acct_123") -> ChatGPTCodex {
        let api = ChatGPTCodex(authorization: ChatGPTCodexAuthorization(
            accessToken: "test-token",
            accountID: accountID
        ))
        attachStub(to: api)
        return api
    }

    private func body(of recorded: CodexBackendStub.RecordedRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: recorded.body) as? [String: Any])
    }

    private func expectCodexWireFormat(
        _ recorded: CodexBackendStub.RecordedRequest
    ) throws -> [String: Any] {
        #expect(recorded.request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(recorded.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(recorded.request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "acct_123")
        #expect(recorded.request.value(forHTTPHeaderField: "originator") == "codex_cli_rs")
        #expect(recorded.request.value(forHTTPHeaderField: "OpenAI-Beta") == nil)

        let body = try body(of: recorded)
        #expect(body["store"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        #expect(body["instructions"] as? String == Self.instructions)
        #expect(body["previous_response_id"] == nil)
        #expect((body["include"] as? [String]) == ["reasoning.encrypted_content"])
        return body
    }

    // MARK: - Authorization headers (no network)

    @Test("authorize sets the codex subscription headers")
    func authorizationHeaders() throws {
        let sessionID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let threadID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let authorization = ChatGPTCodexAuthorization(
            accessToken: "tok",
            accountID: "acct_1",
            sessionID: sessionID,
            threadID: threadID
        )

        var request = URLRequest(url: try #require(URL(string: "https://chatgpt.com/backend-api/codex/responses")))
        authorization.authorize(&request)

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "acct_1")
        #expect(request.value(forHTTPHeaderField: "originator") == "codex_cli_rs")
        #expect(request.value(forHTTPHeaderField: "session-id") == "11111111-2222-3333-4444-555555555555")
        #expect(request.value(forHTTPHeaderField: "thread-id") == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(request.value(forHTTPHeaderField: "x-client-request-id") == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("codex_cli_rs/") == true)
    }

    @Test("ChatGPT-Account-ID is omitted when the account id is nil or empty")
    func accountIDOmitted() throws {
        let url = try #require(URL(string: "https://chatgpt.com/backend-api/codex/responses"))

        var request = URLRequest(url: url)
        ChatGPTCodexAuthorization(accessToken: "tok", accountID: nil).authorize(&request)
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == nil)

        var emptyRequest = URLRequest(url: url)
        ChatGPTCodexAuthorization(accessToken: "tok", accountID: "").authorize(&emptyRequest)
        #expect(emptyRequest.value(forHTTPHeaderField: "ChatGPT-Account-ID") == nil)
    }

    // MARK: - Request building (no network)

    @Test("createUrlRequest rewrites /v1/responses to …/codex/responses and drops OpenAI-Beta")
    func requestPathAndHeaders() throws {
        let api = ChatGPTCodex(authorization: ChatGPTCodexAuthorization(
            accessToken: "tok",
            accountID: "acct_1"
        ))

        let request = try api.createUrlRequest(httpMethod: "POST", path: "/v1/responses")
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "originator") == "codex_cli_rs")
    }

    @Test("state policy is stateless and Responses streaming is preferred")
    func policyAndStreamingPreference() {
        let api = ChatGPTCodex(authorization: ChatGPTCodexAuthorization(
            accessToken: "tok",
            accountID: nil
        ))

        #expect(api.statePolicy == .chatGPTCodex)
        #expect(!api.statePolicy.supportsServerSideHistory)
        #expect(api.prefersResponsesStreaming)
        // The streamed gate must route this configuration onto the
        // Responses-streaming path (there is no chat-completions fallback
        // on the codex backend).
        #expect(Runner.shouldStreamViaResponses(policy: api.statePolicy, outputType: .text))
    }

    // MARK: - Streamed runner (stubbed network)

    @Test("single-turn streamed run sends the codex wire format")
    func singleTurnWireFormat() async throws {
        CodexBackendStub.script([
            CodexFixture.sse([
                CodexFixture.outputItemDone(CodexFixture.messageItem("Hello from codex.")),
                CodexFixture.responseCompleted(id: "resp_1")
            ])
        ])

        let api = makeStubbedCodex()
        let agent = BasicAgent(
            name: "CodexAgent",
            model: "gpt-5.3-codex",
            instructions: Self.instructions
        )

        let result = Runner.runStreamed(agent: agent, input: "Hello?", config: RunConfig(api: api))
        var messages: [String] = []
        for try await event in result.events {
            if case let .runItemEvent(name, item) = event,
               name == .messageOutputCreated,
               case let .message(text) = item {
                messages.append(text)
            }
        }

        #expect(messages == ["Hello from codex."])
        #expect(result.lastResponseId == "resp_1")

        let recorded = CodexBackendStub.recorded
        #expect(recorded.count == 1)
        let request = try #require(recorded.first)
        let requestBody = try expectCodexWireFormat(request)
        #expect(requestBody["model"] as? String == "gpt-5.3-codex")

        let input = try #require(requestBody["input"] as? [[String: Any]])
        #expect(input.count == 1)
        #expect(input.first?["role"] as? String == "user")
    }

    @Test("tool-call turn resends the full accumulated input without chaining")
    func toolCallAccumulatesInput() async throws {
        CodexBackendStub.script([
            // Turn 1: the model thinks, then calls the weather tool.
            CodexFixture.sse([
                CodexFixture.outputItemDone(CodexFixture.reasoningItem),
                CodexFixture.outputItemDone(CodexFixture.functionCallItem),
                CodexFixture.responseCompleted(id: "resp_1")
            ]),
            // Turn 2: with the tool output in context, the model answers.
            CodexFixture.sse([
                CodexFixture.outputItemDone(CodexFixture.messageItem("Mild and cloudy in Berlin.")),
                CodexFixture.responseCompleted(id: "resp_2")
            ])
        ])

        let api = makeStubbedCodex()
        let agent = BasicAgent(
            name: "CodexAgent",
            model: "gpt-5.3-codex",
            instructions: Self.instructions,
            toolProvider: [CodexWeatherTools()]
        )

        let result = Runner.runStreamed(
            agent: agent,
            input: "What's the weather in Berlin?",
            config: RunConfig(api: api)
        )
        for try await _ in result.events {}

        let recorded = CodexBackendStub.recorded
        #expect(recorded.count == 2)

        // Both turns carry the full codex wire format — instructions on
        // EVERY request, store forced false, no previous_response_id.
        let firstBody = try expectCodexWireFormat(try #require(recorded.first))
        let secondBody = try expectCodexWireFormat(try #require(recorded.last))

        let firstInput = try #require(firstBody["input"] as? [[String: Any]])
        #expect(firstInput.count == 1)
        #expect(firstInput.first?["role"] as? String == "user")

        // Turn 2 resends the whole conversation: user message, the turn-1
        // reasoning item (encrypted content intact), the function_call, and
        // the executed tool's output. Server-assigned item ids must be
        // STRIPPED — the backend discards unknown-id items under
        // store:false, orphaning the function_call_output (codex strips
        // them too; `call_id` is the pairing key and stays).
        let secondInput = try #require(secondBody["input"] as? [[String: Any]])
        #expect(secondInput.count == 4)

        #expect(secondInput[0]["role"] as? String == "user")

        #expect(secondInput[1]["type"] as? String == "reasoning")
        #expect(secondInput[1]["id"] == nil)
        #expect(secondInput[1]["encrypted_content"] as? String == "ENCRYPTED_BLOB")

        #expect(secondInput[2]["type"] as? String == "function_call")
        #expect(secondInput[2]["id"] == nil)
        #expect(secondInput[2]["call_id"] as? String == "call_1")
        #expect(secondInput[2]["name"] as? String == "get_weather")

        #expect(secondInput[3]["type"] as? String == "function_call_output")
        #expect(secondInput[3]["call_id"] as? String == "call_1")
        #expect((secondInput[3]["output"] as? String)?.contains("18°C") == true)
    }

    @Test("consecutive runs sharing one InMemorySession replay the full conversation")
    func sessionCarriesConversationAcrossRuns() async throws {
        CodexBackendStub.script([
            // Run 1, turn 1: the model thinks, then calls the weather tool.
            CodexFixture.sse([
                CodexFixture.outputItemDone(CodexFixture.reasoningItem),
                CodexFixture.outputItemDone(CodexFixture.functionCallItem),
                CodexFixture.responseCompleted(id: "resp_1")
            ]),
            // Run 1, turn 2: final answer.
            CodexFixture.sse([
                CodexFixture.outputItemDone(CodexFixture.messageItem("Mild and cloudy in Berlin.")),
                CodexFixture.responseCompleted(id: "resp_2")
            ]),
            // Run 2, turn 1: answer to the follow-up.
            CodexFixture.sse([
                CodexFixture.outputItemDone(CodexFixture.messageItem("Cooler tomorrow.")),
                CodexFixture.responseCompleted(id: "resp_3")
            ])
        ])

        let api = makeStubbedCodex()
        let session = InMemorySession()
        let agent = BasicAgent(
            name: "CodexAgent",
            model: "gpt-5.3-codex",
            instructions: Self.instructions,
            toolProvider: [CodexWeatherTools()]
        )

        let first = Runner.runStreamed(
            agent: agent,
            input: "What's the weather in Berlin?",
            session: session,
            config: RunConfig(api: api)
        )
        for try await _ in first.events {}

        let second = Runner.runStreamed(
            agent: agent,
            input: "And tomorrow?",
            session: session,
            config: RunConfig(api: api)
        )
        for try await _ in second.events {}

        let recorded = CodexBackendStub.recorded
        #expect(recorded.count == 3)

        // The follow-up run's first POST replays the whole first
        // conversation — user message, reasoning (encrypted content
        // intact), tool call and output, assistant reply — before the new
        // user message. Still stateless: instructions present, store
        // false, no previous_response_id.
        let followUpBody = try expectCodexWireFormat(try #require(recorded.last))
        let input = try #require(followUpBody["input"] as? [[String: Any]])
        #expect(input.count == 6)

        #expect(input[0]["role"] as? String == "user")
        let firstUserContent = input[0]["content"] as? [[String: Any]]
        #expect(firstUserContent?.first?["text"] as? String == "What's the weather in Berlin?")

        #expect(input[1]["type"] as? String == "reasoning")
        #expect(input[1]["id"] == nil)
        #expect(input[1]["encrypted_content"] as? String == "ENCRYPTED_BLOB")

        #expect(input[2]["type"] as? String == "function_call")
        #expect(input[2]["id"] == nil)
        #expect(input[2]["call_id"] as? String == "call_1")

        #expect(input[3]["type"] as? String == "function_call_output")
        #expect(input[3]["call_id"] as? String == "call_1")

        #expect(input[4]["role"] as? String == "assistant")
        let assistantContent = input[4]["content"] as? [[String: Any]]
        #expect(assistantContent?.first?["type"] as? String == "output_text")
        #expect(assistantContent?.first?["text"] as? String == "Mild and cloudy in Berlin.")

        #expect(input[5]["role"] as? String == "user")
        let followUpContent = input[5]["content"] as? [[String: Any]]
        #expect(followUpContent?.first?["text"] as? String == "And tomorrow?")
    }

    @Test("stateful OpenAI streamed run without a session still chains previous_response_id")
    func statefulPathUnchangedWithoutSession() async throws {
        CodexBackendStub.script([
            CodexFixture.sse([
                CodexFixture.outputItemDone(CodexFixture.functionCallItem),
                CodexFixture.responseCompleted(id: "resp_1", outputItems: [CodexFixture.functionCallItem])
            ]),
            CodexFixture.sse([
                CodexFixture.outputItemDone(CodexFixture.messageItem("Done.")),
                CodexFixture.responseCompleted(id: "resp_2", outputItems: [CodexFixture.messageItem("Done.")])
            ])
        ])

        let api = OpenAI(credential: Credential.bearer("sk-test"))
        attachStub(to: api)
        let agent = BasicAgent(
            name: "OpenAIAgent",
            model: "gpt-4.1",
            instructions: Self.instructions,
            toolProvider: [CodexWeatherTools()]
        )

        let result = Runner.runStreamed(agent: agent, input: "Call the tool.", config: RunConfig(api: api))
        for try await _ in result.events {}

        let recorded = CodexBackendStub.recorded
        #expect(recorded.count == 2)

        // Turn 1: pre-change wire format, byte for byte — plain-text input,
        // instructions, no include / store / previous_response_id, and the
        // assistants=v2 header the first-party endpoint stamps.
        let firstRequest = try #require(recorded.first)
        #expect(firstRequest.request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(firstRequest.request.value(forHTTPHeaderField: "OpenAI-Beta") == "assistants=v2")
        let firstBody = try body(of: firstRequest)
        #expect(firstBody["input"] as? String == "Call the tool.")
        #expect(firstBody["instructions"] as? String == Self.instructions)
        #expect(firstBody["stream"] as? Bool == true)
        #expect(firstBody["previous_response_id"] == nil)
        #expect(firstBody["store"] == nil)
        #expect(firstBody["include"] == nil)

        // Turn 2: chained via previous_response_id, instructions omitted,
        // and only the tool-output delta as input.
        let secondBody = try body(of: try #require(recorded.last))
        #expect(secondBody["previous_response_id"] as? String == "resp_1")
        #expect(secondBody["instructions"] == nil)
        #expect(secondBody["store"] == nil)
        #expect(secondBody["include"] == nil)
        let delta = try #require(secondBody["input"] as? [[String: Any]])
        #expect(delta.count == 1)
        #expect(delta.first?["type"] as? String == "function_call_output")
        #expect(delta.first?["call_id"] as? String == "call_1")
    }
}
