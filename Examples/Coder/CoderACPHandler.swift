import ACP
import ACPServer
import Foundation
import JSONValue
import SwiftAgents

/// Exposes Coder as an ACP agent.
///
/// Bridges the ACP server harness (`ACPServer`) to SwiftAgents' streaming
/// runner: each ACP `session/prompt` drives `Runner.runStreamed`, whose events
/// are mapped onto `session/update` notifications (text, reasoning, tool calls),
/// and whose provider token usage is returned on the prompt response. Cross-turn
/// continuity is preserved per session via the rolling `lastResponseId`.
final class CoderACPHandler: ACPAgentHandler, @unchecked Sendable {
    private let defaultWorkingDirectory: String
    private let model: String
    private let lock = NSLock()
    private var workingDirectoryBySession: [SessionId: String] = [:]
    private var lastResponseIdBySession: [SessionId: String] = [:]

    init(workingDirectory: String, model: String) {
        defaultWorkingDirectory = workingDirectory
        self.model = model
    }

    func initialize(_: InitializeRequest) async -> InitializeResponse {
        InitializeResponse(
            agentCapabilities: AgentCapabilities(
                loadSession: false,
                promptCapabilities: PromptCapabilities(image: true, audio: false, embeddedContext: false)
            ),
            agentInfo: Implementation(name: "coder", version: "0.1.0"),
            // Coder authenticates via OPENAI_API_KEY in the environment (like codex).
            authMethods: []
        )
    }

    func newSession(_ request: NewSessionRequest) async throws -> NewSessionResponse {
        let id = "coder-\(UUID().uuidString)"
        lock.withLock { workingDirectoryBySession[id] = request.cwd }
        return NewSessionResponse(sessionId: id)
    }

    func prompt(_ request: PromptRequest, session: ACPServerSession) async throws -> PromptResponse {
        let text = request.prompt.compactMap(\.text).joined()
        let (workingDirectory, previousResponseId) = lock.withLock {
            (workingDirectoryBySession[session.id] ?? defaultWorkingDirectory, lastResponseIdBySession[session.id])
        }

        let agent = CodingAgent(workingDirectory: workingDirectory, config: RunConfig(model: model))
        let result = Runner.runStreamed(
            agent: agent, input: text, maxTurns: 50,
            previousResponseId: previousResponseId,
            config: RunConfig(model: model, workFlowName: "ACP Turn")
        )

        var usage: PromptUsage?
        do {
            for try await event in result.events {
                if session.isCancelled {
                    result.cancel()
                    break
                }
                switch event {
                    case let .rawResponseEvent(raw):
                        switch raw.object {
                            case let .outputTextDelta(info):
                                await session.sendText(info.delta)
                            case let .reasoningTextDelta(info):
                                await session.sendThought(info.delta)
                            case let .responseCompleted(response):
                                if let provided = response.usage { usage = Self.mapUsage(provided) }
                            default:
                                break
                        }
                    case let .runItemEvent(name, item):
                        switch (name, item) {
                            case let (.toolCalled, .toolCall(toolName, arguments, callId)):
                                await session.sendToolCall(ToolCall(
                                    toolCallId: callId, title: toolName, kind: Self.toolKind(toolName),
                                    status: .inProgress, rawInput: Self.jsonValue(arguments)
                                ))
                            case let (.toolOutput, .toolOutput(callId, output)):
                                await session.sendToolCallUpdate(ToolCallUpdate(
                                    toolCallId: callId, status: .completed, rawOutput: .string(output)
                                ))
                            default:
                                break
                        }
                    case .agentUpdated:
                        break
                }
            }
        } catch {
            // Surface a failed turn as a JSON-RPC error so the client renders it
            // (the ACP client turns this into `[error] RUNTIME: …`).
            throw JSONRPCErrorBody(code: -32000, message: error.localizedDescription)
        }

        if session.isCancelled { return PromptResponse(stopReason: .cancelled) }

        lock.withLock { lastResponseIdBySession[session.id] = result.lastResponseId }
        return PromptResponse(stopReason: .endTurn, usage: usage)
    }

    // MARK: - Mapping helpers

    /// Map the OpenAI Responses usage onto ACP's token breakdown.
    private static func mapUsage(_ usage: ResponsesUsage) -> PromptUsage {
        PromptUsage(
            inputTokens: Double(usage.inputTokens),
            outputTokens: Double(usage.outputTokens),
            cachedReadTokens: Double(usage.inputTokensDetails.cachedTokens),
            thoughtTokens: Double(usage.outputTokensDetails.reasoningTokens),
            totalTokens: Double(usage.totalTokens)
        )
    }

    /// Map Coder's tool names to ACP tool kinds so clients pick sensible icons.
    private static func toolKind(_ name: String) -> ToolKind {
        switch name {
            case "bash": .execute
            case "read": .read
            case "write", "edit", "apply_patch": .edit
            case "grep", "find", "ls": .search
            default: .other
        }
    }

    /// Parse a tool's JSON argument string into a structured `rawInput`.
    private static func jsonValue(_ argumentsJSON: String) -> JSONValue? {
        guard let data = argumentsJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}
