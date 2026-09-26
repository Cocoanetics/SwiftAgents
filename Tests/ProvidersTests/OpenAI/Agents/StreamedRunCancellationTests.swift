//
//  StreamedRunCancellationTests.swift
//  ProvidersTests
//
//  Offline coverage for tying a streamed run to its consumer: once the code
//  reading `RunResultStreaming.events` stops mid-run — it breaks out of its
//  loop, or its task is cancelled — the background run must stop too, not
//  keep calling tools and starting turns up to `maxTurns` for nobody.
//  Covered on both streaming paths (Responses and the chat-completion
//  fallback).
//
//  No live network: a `URLProtocol` stub answers every model request with
//  another tool call, so a run nobody stops keeps going until `maxTurns`.
//  The tool parks each call until the test opens a gate, holding the run in
//  its first turn while the consumer walks away. Serialized because the
//  stub's request count is process-global.
//

import Foundation
@testable import Agents
@testable import Providers
import SwiftMCP
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Model stub

/// Answers every model request with a `record_step` tool call — on either
/// streaming path — until `toolTurns` are used up, then with a final
/// "Done." message. Counts the requests.
private final class ToolLoopStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0
    nonisolated(unsafe) private static var toolTurns = 0

    /// Resets the request count and scripts how many turns call the tool.
    static func reset(toolTurns: Int = .max) {
        lock.lock()
        defer { lock.unlock() }
        requests = 0
        self.toolTurns = toolTurns
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// Counts a request and returns its 1-based turn and whether it calls the tool.
    private static func nextTurn() -> (turn: Int, callsTool: Bool) {
        lock.lock()
        defer { lock.unlock() }
        requests += 1
        return (requests, requests <= toolTurns)
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (turn, callsTool) = Self.nextTurn()
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let events = url.path.hasSuffix("/chat/completions")
            ? Fixture.chatEvents(turn: turn, callsTool: callsTool)
            : Fixture.responsesEvents(turn: turn, callsTool: callsTool)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Fixture.sse(events))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum Fixture {
    /// Frames JSON event payloads as an SSE byte stream.
    static func sse(_ events: [String]) -> Data {
        Data((events.map { "data: \($0)\n\n" }.joined() + "data: [DONE]\n\n").utf8)
    }

    /// One Responses turn: the output item, then `response.completed`.
    static func responsesEvents(turn: Int, callsTool: Bool) -> [String] {
        let item = callsTool
            ? #"{"type":"function_call","id":"fc_\#(turn)","call_id":"call_\#(turn)","#
            + #""name":"record_step","arguments":"{}","status":"completed"}"#
            : #"{"type":"message","id":"msg_\#(turn)","role":"assistant","status":"completed","#
            + #""content":[{"type":"output_text","text":"Done.","annotations":[]}]}"#
        let response = #"{"id":"resp_\#(turn)","object":"response","created_at":1700000000,"#
            + #""status":"completed","model":"gpt-4.1","output":[\#(item)],"parallel_tool_calls":true,"#
            + #""text":{"format":{"type":"text"}},"tool_choice":"auto","tools":[]}"#
        return [
            #"{"type":"response.output_item.done","output_index":0,"item":\#(item)}"#,
            #"{"type":"response.completed","response":\#(response)}"#
        ]
    }

    /// One chat-completion turn: the delta chunk, then the finish chunk.
    static func chatEvents(turn: Int, callsTool: Bool) -> [String] {
        let delta = callsTool
            ? #"{"role":"assistant","tool_calls":[{"index":0,"id":"call_\#(turn)","type":"function","#
            + #""function":{"name":"record_step","arguments":"{}"}}]}"#
            : #"{"role":"assistant","content":"Done."}"#
        let finishReason = callsTool ? "tool_calls" : "stop"
        let prefix = #"{"id":"chatcmpl_\#(turn)","object":"chat.completion.chunk","#
            + #""created":1700000000,"model":"stub-model","choices":[{"index":0,"#
        return [
            prefix + #""delta":\#(delta),"finish_reason":null}]}"#,
            prefix + #""delta":{},"finish_reason":"\#(finishReason)"}]}"#
        ]
    }
}

extension StreamedRunCancellationTests {
    /// The two paths `Runner.runStreamed` can take.
    enum StreamingPath: CaseIterable {
        /// First-party OpenAI streams via the Responses API.
        case responses
        /// Other OpenAI-compatible endpoints take the chat-completion fallback.
        case chatCompletions

        /// A client for this path whose requests all go to `ToolLoopStub`.
        func makeAPI() throws -> OpenAI {
            let api: OpenAI
            switch self {
                case .responses:
                    api = OpenAI(credential: Credential.bearer("sk-test"))
                case .chatCompletions:
                    let endpoint = try #require(URL(string: "https://chat.example.com"))
                    api = OpenAI(credential: Credential.bearer("sk-test"), endpointURL: endpoint)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ToolLoopStub.self]
            let stubbed = URLSession(configuration: configuration)
            api.session = stubbed
            api.streamSession = stubbed
            return api
        }
    }
}

// MARK: - Test tool

/// Counts `record_step` calls and parks each one until the test opens the
/// gate, so a run can't race past the turn it's in while the test stops
/// consuming.
private actor StepGate {
    private(set) var calls = 0
    private var isOpen: Bool
    private var parkedCalls: [CheckedContinuation<Void, Never>] = []
    private var firstCallWaiters: [CheckedContinuation<Void, Never>] = []

    init(open: Bool = false) {
        isOpen = open
    }

    /// Called by the tool: counts the call, then waits until the gate is open.
    func pass() async {
        calls += 1
        firstCallWaiters.forEach { $0.resume() }
        firstCallWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { parkedCalls.append($0) }
    }

    /// Returns once the tool has been called, i.e. the run is parked in it.
    func firstCall() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { firstCallWaiters.append($0) }
    }

    func open() {
        isOpen = true
        parkedCalls.forEach { $0.resume() }
        parkedCalls.removeAll()
    }
}

@MCPServer
private final class StepTools {
    let gate: StepGate

    init(gate: StepGate) {
        self.gate = gate
    }

    @MCPTool(description: "Records one step of work")
    func record_step() async -> String {
        await gate.pass()
        return "Step recorded."
    }
}

// MARK: - Tests

@Suite(.serialized)
struct StreamedRunCancellationTests {
    /// Starts a run of up to five turns for an agent whose tool is `record_step`.
    private func startRun(on path: StreamingPath, gate: StepGate) throws -> RunResultStreaming {
        let agent = BasicAgent(
            name: "StepAgent",
            model: "gpt-4.1",
            instructions: "Record steps until you are done.",
            toolProvider: [StepTools(gate: gate)]
        )
        let api = try path.makeAPI()
        return Runner.runStreamed(
            agent: agent,
            input: "Start working.",
            maxTurns: 5,
            config: RunConfig(api: api)
        )
    }

    @Test("breaking out of the event loop stops the run", arguments: StreamingPath.allCases)
    func breakingOutStopsRun(path: StreamingPath) async throws {
        ToolLoopStub.reset()
        let gate = StepGate()
        let result = try startRun(on: path, gate: gate)

        // Walk away while the run is parked inside its first tool call.
        for try await event in result.events {
            if case .runItemEvent(.toolCalled, _) = event {
                await gate.firstCall()
                break
            }
        }

        // Leaving the loop cancelled the run — no `cancel()` call needed —
        // so once the parked tool call returns, the run ends right there
        // instead of starting the four turns it has left.
        #expect(result.task.isCancelled)
        await gate.open()
        _ = await result.task.result

        #expect(await gate.calls == 1)
        #expect(ToolLoopStub.requestCount == 1)
    }

    @Test("cancelling the consuming task stops the run", arguments: StreamingPath.allCases)
    func cancellingConsumerStopsRun(path: StreamingPath) async throws {
        ToolLoopStub.reset()
        let gate = StepGate()
        let result = try startRun(on: path, gate: gate)

        // Cancel the consumer while the run is parked inside its first tool
        // call. Its loop just ends — a cancelled stream consumer sees the
        // end, not an error — so nothing but the stream can stop the run.
        let consumer = Task {
            for try await _ in result.events {}
        }
        await gate.firstCall()
        consumer.cancel()
        _ = await consumer.result

        #expect(result.task.isCancelled)
        await gate.open()
        _ = await result.task.result

        #expect(await gate.calls == 1)
        #expect(ToolLoopStub.requestCount == 1)
    }

    @Test("a run consumed to the end completes uncancelled", arguments: StreamingPath.allCases)
    func fullyConsumedRunCompletes(path: StreamingPath) async throws {
        ToolLoopStub.reset(toolTurns: 1)
        let gate = StepGate(open: true)
        let result = try startRun(on: path, gate: gate)

        var messages: [String] = []
        for try await event in result.events {
            if case let .runItemEvent(.messageOutputCreated, .message(text)) = event {
                messages.append(text)
            }
        }

        // Releasing a stream that reached the end must not cancel the
        // (already finished) run.
        #expect(messages == ["Done."])
        #expect(!result.task.isCancelled)
        try await result.task.value
        #expect(await gate.calls == 1)
        #expect(ToolLoopStub.requestCount == 2)
    }
}
