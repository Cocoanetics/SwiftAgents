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
///
/// Sessions are also persisted to disk (``CoderSessionStore``) so `session/load`
/// can resume them after the process restarts, and each session carries a
/// **mode** (`code` = full tools, `plan` = read-only, via `session/set_mode`) and
/// a **reasoning-effort** config option (`session/set_config_option`).
final class CoderACPHandler: ACPAgentHandler, @unchecked Sendable {
    private let defaultWorkingDirectory: String
    private let model: String
    private let store: CoderSessionStore
    private let lock = NSLock()
    private var sessions: [SessionId: LiveSession] = [:]

    /// The live, in-memory state for one session. The durable slice persists via
    /// ``CoderSessionState`` (``persisted(id:)``); the MCP proxies and the deferred
    /// setup notice stay in memory only.
    private struct LiveSession {
        var cwd: String
        var model: String
        var modeId: String
        var reasoningEffort: String
        var lastResponseId: String?
        var history: [CoderSessionState.Turn]
        /// Connected per-session MCP server proxies. Never torn down on
        /// `cancel(sessionId:)` — that's per-turn cancellation and later turns
        /// still need the servers. ACP has no session-teardown hook, so they live
        /// until the process exits (the spawned stdio children exit with it, on EOF).
        var mcpProxies: [MCPServerProxy]
        /// Servers that couldn't be set up on `session/new` (connect failure or an
        /// unsupported network transport), surfaced on the session's first prompt.
        var mcpNotice: String?

        func persisted(id: SessionId) -> CoderSessionState {
            CoderSessionState(
                sessionId: id, cwd: cwd, model: model, modeId: modeId,
                reasoningEffort: reasoningEffort, lastResponseId: lastResponseId,
                history: history
            )
        }

        /// Append a turn's user + assistant text, trimming to the newest
        /// ``CoderACPHandler/maxHistoryMessages`` so the on-disk file stays bounded
        /// (the provider still holds full context via `lastResponseId`).
        mutating func appendTurn(user: String, assistant: String) {
            if !user.isEmpty { history.append(.init(role: .user, text: user)) }
            if !assistant.isEmpty { history.append(.init(role: .assistant, text: assistant)) }
            let cap = CoderACPHandler.maxHistoryMessages
            if history.count > cap { history.removeFirst(history.count - cap) }
        }
    }

    // MARK: - Modes & config option vocabulary

    static let codeModeId = "code"
    static let planModeId = "plan"
    static let reasoningConfigId = "reasoning_effort"
    static let defaultReasoning = "auto"
    /// Selectable reasoning-effort values, paired with display names. `auto` leaves
    /// the provider default in place; the rest map to ``Reasoning/Effort``.
    static let reasoningValues: [(id: String, name: String)] =
        [("auto", "Auto"), ("low", "Low"), ("medium", "Medium"), ("high", "High")]
    /// Cap on the transcript we keep for replay — the provider still holds full
    /// context via `lastResponseId`, so this only bounds the on-disk file.
    static let maxHistoryMessages = 40

    init(workingDirectory: String, model: String, store: CoderSessionStore = CoderSessionStore()) {
        defaultWorkingDirectory = workingDirectory
        self.model = model
        self.store = store
    }

    func initialize(_: InitializeRequest) async -> InitializeResponse {
        InitializeResponse(
            agentCapabilities: AgentCapabilities(
                // Sessions persist to disk, so we can resume them across restarts.
                loadSession: true,
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
        let live = LiveSession(
            cwd: request.cwd, model: model, modeId: Self.codeModeId,
            reasoningEffort: Self.defaultReasoning, lastResponseId: nil, history: [],
            mcpProxies: proxies, mcpNotice: notice
        )
        lock.withLock { sessions[id] = live }
        persist(id)
        // Advertise the model menu, the mode menu, and the config options so native
        // ACP clients render a model picker, a mode switch, and an options panel.
        return NewSessionResponse(
            sessionId: id,
            modelState: Self.modelState(current: model),
            modes: Self.modeState(current: Self.codeModeId),
            configOptions: Self.configOptions(effort: Self.defaultReasoning)
        )
    }

    /// Resume a previously created session after a process restart (`session/load`).
    /// Restores the durable state from disk, reconnects the MCP servers the client
    /// re-supplies, replays the light transcript so the client rebuilds its view,
    /// and re-advertises the model / mode / config menus.
    func loadSession(_ request: LoadSessionRequest, session: ACPServerSession) async throws
        -> LoadSessionResponse {
        guard let state = store.load(request.sessionId) else {
            throw JSONRPCErrorBody(code: -32602, message: "Unknown session: \(request.sessionId)")
        }
        // The client re-supplies MCP servers on load; the persisted record keeps no
        // live handles, so reconnect them against the session's working directory.
        let (proxies, notice) = await Self.connectMCPServers(request.mcpServers, cwd: state.cwd)

        // The rolling `lastResponseId` only resumes the conversation for providers
        // that keep history server-side (OpenAI Responses, LM Studio). For stateless
        // providers (Anthropic, Gemini, Ollama) the id can't rebuild context after a
        // restart, so drop it and tell the client the model starts fresh — otherwise
        // the replayed transcript below would imply a memory the model doesn't have.
        let resumable = await Self.providerResumesFromResponseId(state.model)
        let live = LiveSession(
            cwd: state.cwd, model: state.model, modeId: state.modeId,
            reasoningEffort: state.reasoningEffort,
            lastResponseId: resumable ? state.lastResponseId : nil,
            history: state.history, mcpProxies: proxies, mcpNotice: notice
        )
        lock.withLock { sessions[request.sessionId] = live }

        // Replay the transcript so the client can rebuild the conversation view.
        for turn in state.history {
            switch turn.role {
                case .user: await session.update(.userMessageChunk(.text(turn.text)))
                case .assistant: await session.sendText(turn.text)
            }
        }
        if !resumable, !state.history.isEmpty {
            await session.sendText(
                "\n_Note: \(state.model) keeps no server-side conversation state, so the "
                    + "messages above aren't in my context after a restart — please restate "
                    + "anything I need to carry forward._")
        }

        return LoadSessionResponse(
            modelState: Self.modelState(current: state.model),
            modes: Self.modeState(current: state.modeId),
            configOptions: Self.configOptions(effort: state.reasoningEffort)
        )
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

    // MARK: - Session controls

    /// Switch the session mode (`session/set_mode`) between `code` (full tools) and
    /// `plan` (read-only). Confirms the change with a `current_mode_update`.
    func setMode(_ request: SetSessionModeRequest, session: ACPServerSession) async throws {
        guard [Self.codeModeId, Self.planModeId].contains(request.modeId) else {
            throw JSONRPCErrorBody(code: -32602, message: "Unknown mode: \(request.modeId)")
        }
        guard updateSession(request.sessionId, { $0.modeId = request.modeId }) else {
            throw JSONRPCErrorBody(code: -32602, message: "Unknown session: \(request.sessionId)")
        }
        persist(request.sessionId)
        await session.sendModeUpdate(request.modeId)
    }

    /// Set the reasoning-effort config option (`session/set_config_option`) and
    /// return the updated option set so the client re-renders it.
    func setConfigOption(
        _ request: SetSessionConfigOptionRequest, session _: ACPServerSession
    ) async throws -> SetSessionConfigOptionResponse {
        guard request.configId == Self.reasoningConfigId else {
            throw JSONRPCErrorBody(code: -32602, message: "Unknown config option: \(request.configId)")
        }
        guard Self.reasoningValues.contains(where: { $0.id == request.value }) else {
            throw JSONRPCErrorBody(
                code: -32602,
                message: "Invalid \(Self.reasoningConfigId): \(request.value) "
                    + "(expected one of \(Self.reasoningValues.map(\.id).joined(separator: ", ")))"
            )
        }
        guard updateSession(request.sessionId, { $0.reasoningEffort = request.value }) else {
            throw JSONRPCErrorBody(code: -32602, message: "Unknown session: \(request.sessionId)")
        }
        persist(request.sessionId)
        return SetSessionConfigOptionResponse(configOptions: Self.configOptions(effort: request.value))
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
        // Deferred setup problems from `session/new` (see `LiveSession.mcpNotice`),
        // reported once on the session's first prompt.
        let notice = withSession(session.id) { live -> String? in
            defer { live.mcpNotice = nil }
            return live.mcpNotice
        } ?? nil
        if let notice {
            await session.sendText(notice + "\n\n")
        }

        let text = request.prompt.compactMap(\.text).joined()

        // Intercept known slash commands before the model. Anything else (incl.
        // unknown "/foo") flows to the model as plain text.
        if let command = Self.parseSlashCommand(request.prompt) {
            switch command.name {
                case "new":
                    updateSession(session.id) { session in
                        session.lastResponseId = nil
                        session.history = []
                    }
                    persist(session.id)
                    await session.sendText("Started a new conversation — earlier context cleared.")
                    return PromptResponse(stopReason: .endTurn)
                case "model":
                    return await handleModelCommand(command.rest, session: session)
                default:
                    break
            }
        }

        guard let snapshot = lock.withLock({ sessions[session.id] }) else {
            throw JSONRPCErrorBody(code: -32602, message: "Unknown session: \(session.id)")
        }

        let planMode = snapshot.modeId == Self.planModeId
        let agent = CodingAgent(
            workingDirectory: snapshot.cwd,
            readOnly: planMode,
            reasoningEffort: Self.effort(from: snapshot.reasoningEffort),
            config: RunConfig(model: snapshot.model),
            // Plan mode is read-only, so withhold the client's MCP servers too: their
            // tools bypass `readOnly`/`ensureWritable` and a filesystem or shell MCP
            // server could otherwise write files or run commands in "read-only" mode.
            mcpServers: planMode ? [] : snapshot.mcpProxies
        )
        let result = Runner.runStreamed(
            agent: agent, input: text, maxTurns: 50,
            previousResponseId: snapshot.lastResponseId,
            config: RunConfig(model: snapshot.model, workFlowName: "ACP Turn")
        )

        var usage: PromptUsage?
        var assistantText = ""
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
                                assistantText += info.delta
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

        // Record the turn (rolling response id + transcript) and persist it so the
        // session can be resumed after a restart.
        updateSession(session.id) { live in
            live.lastResponseId = result.lastResponseId
            live.appendTurn(user: text, assistant: assistantText)
        }
        persist(session.id)
        return PromptResponse(stopReason: .endTurn, usage: usage)
    }

    // MARK: - Per-session state helpers

    /// Read a value out of the live session under the lock, or `nil` if unknown.
    private func withSession<T>(_ id: SessionId, _ body: (inout LiveSession) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard var live = sessions[id] else { return nil }
        let result = body(&live)
        sessions[id] = live
        return result
    }

    /// Mutate the live session under the lock; `false` if the session is unknown.
    @discardableResult
    private func updateSession(_ id: SessionId, _ body: (inout LiveSession) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var live = sessions[id] else { return false }
        body(&live)
        sessions[id] = live
        return true
    }

    /// Snapshot the durable state under the lock and write it out (I/O off-lock).
    private func persist(_ id: SessionId) {
        guard let state = lock.withLock({ sessions[id]?.persisted(id: id) }) else { return }
        store.save(state)
    }

    // MARK: - Menus (models / modes / config options)

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

    /// The mode menu: `code` (full tools) vs. `plan` (read-only exploration).
    private static func modeState(current: String) -> SessionModeState {
        SessionModeState(
            currentModeId: current,
            availableModes: [
                SessionMode(
                    id: codeModeId, name: "Code",
                    description: "Full tool access — read, search, run commands, and edit files."
                ),
                SessionMode(
                    id: planModeId, name: "Plan",
                    description: "Read-only — explore and propose a plan without changing files."
                )
            ]
        )
    }

    /// The config-option panel: a single `reasoning_effort` "select" option, shaped
    /// the way acpx recognises (`type`/`id`/`currentValue`/`options`).
    private static func configOptions(effort current: String) -> [JSONValue] {
        [.object([
            "id": .string(reasoningConfigId),
            "type": .string("select"),
            "name": .string("Reasoning effort"),
            "description": .string("How hard the model thinks before answering (reasoning-capable models)."),
            "currentValue": .string(current),
            "options": .array(reasoningValues.map {
                .object(["id": .string($0.id), "name": .string($0.name)])
            })
        ])]
    }

    /// Whether a turn on `model` can resume from a stored `lastResponseId` — true
    /// only for providers that keep conversation history server-side (OpenAI
    /// Responses, LM Studio). Defaults to `true` when the provider can't be resolved
    /// (e.g. no key in the environment): such a session can't run a turn anyway, so
    /// there's nothing to warn about.
    private static func providerResumesFromResponseId(_ model: String) async -> Bool {
        guard let api = try? await ProviderRegistry.shared.api(for: model) else { return true }
        return api.statePolicy.supportsServerSideHistory
    }

    /// Map a stored reasoning-effort value to the model setting. `auto` (and any
    /// unknown value) leaves the provider default in place.
    private static func effort(from value: String) -> Reasoning.Effort? {
        switch value {
            case "low": .low
            case "medium": .medium
            case "high": .high
            default: nil
        }
    }

    // MARK: - Slash commands

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
            let current = lock.withLock { sessions[session.id]?.model ?? model }
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
        guard updateSession(sessionId, { session in
            session.model = target
            session.lastResponseId = nil
        }) else {
            throw JSONRPCErrorBody(code: -32602, message: "Unknown session: \(sessionId)")
        }
        persist(sessionId)
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
