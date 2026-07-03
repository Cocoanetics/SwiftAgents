import Foundation
import JSONFoundation
import SwiftACP
import SwiftAgents
import SwiftMCP

/// Exposes Coder as an ACP agent.
///
/// Bridges the ACP server harness (`ACPServer`) to SwiftAgents' streaming
/// runner: each ACP `session/prompt` drives `Runner.runStreamed`, whose events
/// are mapped onto `session/update` notifications (text, reasoning, tool calls),
/// and whose provider token usage is returned on the prompt response. Cross-turn
/// continuity is preserved per session via the rolling `lastResponseId`, and the
/// stdio MCP servers a client configures on `session/new` are spawned once per
/// session and exposed to the agent as extra tools.
final class CoderACPHandler: ACPAgentHandler, @unchecked Sendable {
    private let defaultWorkingDirectory: String
    private let model: String
    private let lock = NSLock()
    private var workingDirectoryBySession: [SessionId: String] = [:]
    private var lastResponseIdBySession: [SessionId: String] = [:]
    private var modelBySession: [SessionId: String] = [:]
    /// Connected per-session MCP server proxies. Never torn down on
    /// `cancel(sessionId:)` — that's per-turn cancellation and later turns still
    /// need the servers. ACP has no session-teardown hook, so they live until the
    /// process exits (the spawned stdio children exit with it, on stdin EOF).
    private var mcpProxiesBySession: [SessionId: [MCPServerProxy]] = [:]
    /// Servers that couldn't be set up on `session/new` (connect failure or an
    /// unsupported network transport). `newSession` has no `ACPServerSession` to
    /// stream text through, so the notice is surfaced on the session's first prompt.
    private var mcpNoticeBySession: [SessionId: String] = [:]

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
        let (proxies, notice) = await Self.connectMCPServers(request.mcpServers, cwd: request.cwd)
        lock.withLock {
            workingDirectoryBySession[id] = request.cwd
            mcpProxiesBySession[id] = proxies
            mcpNoticeBySession[id] = notice
        }
        // Advertise the model menu so native ACP clients render a model picker.
        return NewSessionResponse(sessionId: id, modelState: Self.modelState(current: model))
    }

    /// Spawn and connect the stdio MCP servers a client configured for the session.
    /// A per-server connect failure must not fail session creation, so failures —
    /// and non-stdio specs, whose network transports Coder doesn't support — are
    /// collected into a notice for the first prompt instead of thrown.
    private static func connectMCPServers(
        _ specs: [MCPServerSpec], cwd: String
    ) async -> (proxies: [MCPServerProxy], notice: String?) {
        var proxies: [MCPServerProxy] = []
        var problems: [String] = []
        for spec in specs {
            switch spec {
                case let .stdio(server):
                    let proxy = MCPServerProxy(config: .stdio(config: MCPServerStdioConfig(
                        command: server.command,
                        args: server.args,
                        workingDirectory: cwd,
                        // Clients may repeat a variable name; last occurrence wins.
                        environment: Dictionary(
                            server.env.map { ($0.name, $0.value) },
                            uniquingKeysWith: { _, last in last }
                        )
                    )))
                    do {
                        try await proxy.connect()
                        proxies.append(proxy)
                    } catch {
                        problems.append("\(server.name) failed to connect: \(error.localizedDescription)")
                    }
                case let .other(value):
                    let name = value["name"]?.stringValue ?? "unnamed"
                    problems.append("\(name) uses an unsupported transport (only stdio MCP servers are supported)")
            }
        }
        guard !problems.isEmpty else { return (proxies, nil) }
        return (proxies, "Skipped MCP server(s) — " + problems.joined(separator: "; ") + ".")
    }

    /// Native model switch (`session/set_model`). Shares one code path with the
    /// `/model <id>` slash command, so both write the same per-session state.
    func setModel(_ request: SetSessionModelRequest) async throws {
        try await switchModel(to: request.modelId, sessionId: request.sessionId)
    }

    /// Slash commands the client should offer (published on session start).
    func availableCommands(for _: SessionId) async -> [AvailableCommand] {
        [
            AvailableCommand(name: "new", description: "Start a fresh conversation (clear the context)."),
            AvailableCommand(
                name: "model",
                description: "Show the current model, or switch with /model <id> (e.g. claude-sonnet-4-5).",
                input: .object(["hint": .string("model id")])
            )
        ]
    }

    func prompt(_ request: PromptRequest, session: ACPServerSession) async throws -> PromptResponse {
        // Deferred setup problems from `session/new` (see `mcpNoticeBySession`),
        // reported once on the session's first prompt.
        if let notice = lock.withLock({ mcpNoticeBySession.removeValue(forKey: session.id) }) {
            await session.sendText(notice + "\n\n")
        }

        let text = request.prompt.compactMap(\.text).joined()

        // Intercept known slash commands before the model. Anything else (incl.
        // unknown "/foo") flows to the model as plain text.
        if let command = Self.parseSlashCommand(request.prompt) {
            switch command.name {
                case "new":
                    lock.withLock { lastResponseIdBySession[session.id] = nil }
                    await session.sendText("Started a new conversation — earlier context cleared.")
                    return PromptResponse(stopReason: .endTurn)
                case "model":
                    return await handleModelCommand(command.rest, session: session)
                default:
                    break
            }
        }

        let (workingDirectory, previousResponseId, currentModel, mcpServers) = lock.withLock {
            (
                workingDirectoryBySession[session.id] ?? defaultWorkingDirectory,
                lastResponseIdBySession[session.id],
                modelBySession[session.id] ?? model,
                mcpProxiesBySession[session.id] ?? []
            )
        }

        let agent = CodingAgent(
            workingDirectory: workingDirectory,
            config: RunConfig(model: currentModel),
            mcpServers: mcpServers
        )
        let result = Runner.runStreamed(
            agent: agent, input: text, maxTurns: 50,
            previousResponseId: previousResponseId,
            config: RunConfig(model: currentModel, workFlowName: "ACP Turn")
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

    /// Parse a leading `/command [args]` out of the prompt's first text block,
    /// mirroring how ACP clients send slash commands (as ordinary prompt text).
    private static func parseSlashCommand(_ prompt: [ContentBlock]) -> (name: String, rest: String)? {
        guard let first = prompt.first, let text = first.text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
    }

    /// `/model [id]`: with no id, report the current model + which provider keys
    /// are present; with an id, switch via ``switchModel(to:sessionId:)`` (the
    /// same path `session/set_model` uses), reporting any rejection in-band.
    private func handleModelCommand(_ rest: String, session: ACPServerSession) async -> PromptResponse {
        let target = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty {
            let current = lock.withLock { modelBySession[session.id] ?? model }
            await session.sendText("Model: \(current)\n\(Self.availableProvidersSummary())")
            return PromptResponse(stopReason: .endTurn)
        }
        do {
            try await switchModel(to: target, sessionId: session.id)
        } catch {
            await session.sendText("Can't switch to \(target): \(error.localizedDescription)")
            return PromptResponse(stopReason: .endTurn)
        }
        await session.sendText("Model set to \(target).")
        return PromptResponse(stopReason: .endTurn)
    }

    /// Validate `target` against the provider registry (its provider must be known
    /// *and* its key present in the environment) and switch this session to it,
    /// clearing the rolling response id — provider-stateful continuity can't carry
    /// across a provider change. Throws on an invalid target: `session/set_model`
    /// surfaces that to the client, while `/model` catches it for a friendly note.
    private func switchModel(to target: String, sessionId: SessionId) async throws {
        _ = try await ProviderRegistry.shared.api(for: target)
        lock.withLock {
            modelBySession[sessionId] = target
            lastResponseIdBySession[sessionId] = nil
        }
    }

    /// The model menu advertised to ACP clients (drives a native model picker)
    /// and the basis for `/model`'s suggestions. SwiftAgents has no model catalog
    /// — `ProviderRegistry` only *routes* an id to a provider — so this is a
    /// curated, conservative set per provider whose key is present. The switch
    /// paths still accept ANY routable id (validated on use), so newer models work
    /// even when not listed. The current model is always selectable.
    private static func modelState(current: String) -> SessionModelState {
        let env = ProcessInfo.processInfo.environment
        var models: [ModelInfo] = []
        func add(_ id: String, _ name: String) {
            guard !models.contains(where: { $0.modelId == id }) else { return }
            models.append(ModelInfo(modelId: id, name: name))
        }
        add(current, current)
        if env["OPENAI_API_KEY"] != nil { add("gpt-5.4", "GPT-5.4") }
        if env["ANTHROPIC_API_KEY"] != nil { add("claude-sonnet-4-5", "Claude Sonnet 4.5") }
        if env["GEMINI_API_KEY"] != nil {
            add("gemini-2.5-pro", "Gemini 2.5 Pro")
            add("gemini-2.5-flash", "Gemini 2.5 Flash")
        }
        return SessionModelState(currentModelId: current, availableModels: models)
    }

    /// Which providers have credentials in the environment — drives what `/model`
    /// can switch to. (Local providers ollama/lmstudio need a reachable URL, not a key.)
    private static func availableProvidersSummary() -> String {
        let env = ProcessInfo.processInfo.environment
        var available: [String] = []
        if env["OPENAI_API_KEY"] != nil { available.append("openai (gpt-*, o*)") }
        if env["ANTHROPIC_API_KEY"] != nil { available.append("anthropic (claude-*)") }
        if env["GEMINI_API_KEY"] != nil { available.append("google (gemini-*)") }
        if env["OLLAMA_URL"] != nil { available.append("ollama (ollama/<model>)") }
        if env["LMSTUDIO_URL"] != nil { available.append("lmstudio (lmstudio/<model>)") }
        return available.isEmpty
            ? "No provider keys found in the environment."
            : "Providers with keys: " + available.joined(separator: ", ") + ". Switch with /model <id>."
    }

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
