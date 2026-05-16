import Foundation
@testable import Providers
import SwiftMCP
import Testing

private final class TestAdderToolProvider: MCPToolProviding, @unchecked Sendable {
    var mcpToolMetadata: [MCPToolMetadata] {
        [
            MCPToolMetadata(
                name: "add_numbers",
                description: "Add two numbers and return the sum.",
                parameters: [
                    MCPParameterInfo(
                        name: "lhs",
                        type: Double.self,
                        description: "Left-hand number.",
                        isRequired: true
                    ),
                    MCPParameterInfo(
                        name: "rhs",
                        type: Double.self,
                        description: "Right-hand number.",
                        isRequired: true
                    )
                ],
                returnType: Double.self,
                returnTypeDescription: "The numeric sum.",
                isConsequential: false
            )
        ]
    }

    func callTool(_ name: String, arguments: JSONDictionary) async throws -> Encodable & Sendable {
        guard name == "add_numbers" else {
            throw APIError.invalidRequest("Unexpected tool name \(name)")
        }

        let lhs = try #require(arguments["lhs"]?.doubleValue, "lhs must be present")
        let rhs = try #require(arguments["rhs"]?.doubleValue, "rhs must be present")
        return lhs + rhs
    }
}

private actor MockRealtimeModel: RealtimeModel {
    private let encoder = OpenAI(apiKey: "test").encoder
    private let streamPair = AsyncThrowingStream<RealtimeServerEvent, Error>.makeStream()
    private var sentEvents = [Data]()

    func connect() async throws -> AsyncThrowingStream<RealtimeServerEvent, Error> {
        streamPair.stream
    }

    func send(_ event: some Encodable & Sendable) async throws {
        try sentEvents.append(encoder.encode(event))
    }

    func sendRaw(_ payload: [String: JSONValue]) async throws {
        try sentEvents.append(encoder.encode(payload))
    }

    func disconnect() async {
        streamPair.continuation.finish()
    }

    func emit(_ event: RealtimeServerEvent) {
        streamPair.continuation.yield(event)
    }

    func sentPayloads() -> [Data] {
        sentEvents
    }
}

struct RealtimeSessionTests {
    @Test("Realtime session sends session.update before prompting")
    func sessionSendsInitialConfigurationAndPrompt() async throws {
        let model = MockRealtimeModel()
        let agent = BasicRealtimeAgent(
            name: "Realtime Test Agent",
            instructions: "Be concise.",
            sessionConfiguration: RealtimeSessionConfiguration(outputModalities: [.text])
        )

        let session = RealtimeSession(agent: agent, model: model, modelIdentifier: "gpt-realtime")
        try await session.connect()
        try await session.sendMessage("Hello realtime")

        let payloads = try await decodedPayloads(from: model)

        let updatePayload = try #require(payloads.first)
        #expect(updatePayload["type"] as? String == "session.update")

        let sessionPayload = try #require(updatePayload["session"] as? [String: Any])
        let outputModalities = try #require(sessionPayload["output_modalities"] as? [String])
        #expect(outputModalities == ["text"])
        #expect(sessionPayload["instructions"] as? String == "Be concise.")

        let itemCreatePayload = try #require(payloads[safe: 1])
        #expect(itemCreatePayload["type"] as? String == "conversation.item.create")

        let item = try #require(itemCreatePayload["item"] as? [String: Any])
        #expect(item["type"] as? String == "message")
        #expect(item["role"] as? String == "user")

        let content = try #require(item["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "Hello realtime")

        let responseCreatePayload = try #require(payloads[safe: 2])
        #expect(responseCreatePayload["type"] as? String == "response.create")

        await session.disconnect()
    }

    @Test("Realtime session executes function calls and reinserts outputs")
    func sessionExecutesToolCallsInsideTheActiveSession() async throws {
        let model = MockRealtimeModel()
        let agent = BasicRealtimeAgent(
            name: "Realtime Calculator",
            instructions: "Use add_numbers for arithmetic.",
            toolProvider: [TestAdderToolProvider()],
            sessionConfiguration: RealtimeSessionConfiguration(outputModalities: [.text])
        )

        let session = RealtimeSession(agent: agent, model: model, modelIdentifier: "gpt-realtime")
        try await session.connect()
        try await session.sendMessage("What is 2 + 3?")

        await model.emit(
            RealtimeServerEvent(
                type: "response.created",
                eventId: "evt_response_created",
                object: .responseCreated(
                    .init(
                        eventId: "evt_response_created",
                        response: RealtimeResponse(id: "resp_1", status: .inProgress)
                    )
                )
            )
        )

        let functionCall = OutputItem.FunctionCall(
            id: "item_fc_1",
            callId: "call_1",
            name: "add_numbers",
            arguments: #"{"lhs":2,"rhs":3}"#,
            status: .completed
        )

        await model.emit(
            RealtimeServerEvent(
                type: "response.done",
                eventId: "evt_response_done",
                object: .responseDone(
                    .init(
                        eventId: "evt_response_done",
                        response: RealtimeResponse(
                            id: "resp_1",
                            status: .completed,
                            output: [.functionCall(functionCall)],
                            conversationId: "conv_1"
                        )
                    )
                )
            )
        )

        // Wait for the SDK to execute the tool call and dispatch the
        // follow-up `response.create`. Then emit the matching
        // `response.created` + `response.done` that the real OpenAI
        // server would send back — without those, `waitUntilIdle()`
        // blocks forever because the SDK's `pendingResponseRequests`
        // counter stays at 1.
        try await Task.sleep(nanoseconds: 100_000_000)

        await model.emit(
            RealtimeServerEvent(
                type: "response.created",
                eventId: "evt_response_created_2",
                object: .responseCreated(
                    .init(
                        eventId: "evt_response_created_2",
                        response: RealtimeResponse(id: "resp_2", status: .inProgress)
                    )
                )
            )
        )
        await model.emit(
            RealtimeServerEvent(
                type: "response.done",
                eventId: "evt_response_done_2",
                object: .responseDone(
                    .init(
                        eventId: "evt_response_done_2",
                        response: RealtimeResponse(
                            id: "resp_2",
                            status: .completed,
                            conversationId: "conv_1"
                        )
                    )
                )
            )
        )

        try await session.waitUntilIdle()

        let payloads = try await decodedPayloads(from: model)
        let functionOutputPayload = try #require(payloads.last(where: { payload in
            guard payload["type"] as? String == "conversation.item.create" else {
                return false
            }

            let item = payload["item"] as? [String: Any]
            return item?["type"] as? String == "function_call_output"
        }))

        let functionOutputItem = try #require(functionOutputPayload["item"] as? [String: Any])
        #expect(functionOutputItem["call_id"] as? String == "call_1")
        #expect(functionOutputItem["output"] as? String == "5")

        let responseCreateCount = payloads.filter { $0["type"] as? String == "response.create" }.count
        #expect(responseCreateCount == 2)

        await session.disconnect()
    }

    private func decodedPayloads(from model: MockRealtimeModel) async throws -> [[String: Any]] {
        try await model.sentPayloads().map { payload in
            let jsonObject = try JSONSerialization.jsonObject(with: payload)
            return try #require(jsonObject as? [String: Any], "Expected JSON object payload")
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
