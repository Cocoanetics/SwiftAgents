import Foundation
import SwiftMCP

public enum RealtimeSessionEvent: Sendable {
    case raw(RealtimeServerEvent)
    case sessionCreated(RealtimeSessionConfiguration)
    case sessionUpdated(RealtimeSessionConfiguration)
    case historyChange(RealtimeHistory.Change)
    case textDelta(RealtimeServerEvent.OutputTextDeltaEvent)
    case textDone(RealtimeServerEvent.OutputTextDoneEvent)
    case audioDelta(RealtimeServerEvent.OutputAudioDeltaEvent)
    case audioDone(RealtimeServerEvent.OutputAudioDoneEvent)
    case inputAudioTranscriptDelta(RealtimeServerEvent.InputAudioTranscriptionDeltaEvent)
    case inputAudioTranscriptDone(RealtimeServerEvent.InputAudioTranscriptionCompletedEvent)
    case outputAudioTranscriptDelta(RealtimeServerEvent.OutputAudioTranscriptDeltaEvent)
    case outputAudioTranscriptDone(RealtimeServerEvent.OutputAudioTranscriptDoneEvent)
    case toolCalled(OutputItem.FunctionCall)
    case toolOutput(FunctionCallOutput)
    case responseCompleted(RealtimeResponse)
    case error(ErrorDetail)
}

public enum RealtimeSessionError: LocalizedError {
    case alreadyConnected
    case notConnected
    case modelChangeRequiresNewSession(current: String, requested: String)

    public var errorDescription: String? {
        switch self {
            case .alreadyConnected:
                return "Realtime session is already connected"
            case .notConnected:
                return "Realtime session is not connected"
            case let .modelChangeRequiresNewSession(current, requested):
                return """
                Realtime sessions cannot change model from \(current) to \(requested) \
                after the WebSocket has connected. Start a new session instead.
                """
        }
    }
}

public actor RealtimeSession {
    public let events: AsyncThrowingStream<RealtimeSessionEvent, Error>
    public let history: RealtimeHistory

    private let eventContinuation: AsyncThrowingStream<RealtimeSessionEvent, Error>.Continuation
    private let model: any RealtimeModel
    private let initialModelIdentifier: String

    private var currentAgent: any RealtimeAgent
    private var currentSessionConfiguration: RealtimeSessionConfiguration?
    private var conversationID: String?
    private var isConnected = false
    private var hasFinished = false
    private var eventTask: Task<Void, Never>?
    private var lastServerError: Error?
    private var activeResponses = 0
    private var pendingResponseRequests = 0
    private var pendingToolContinuations = 0
    private var idleWaiters = [CheckedContinuation<Void, Error>]()

    public init(
        agent: any RealtimeAgent,
        model: any RealtimeModel,
        modelIdentifier: String? = nil
    ) {
        let (events, continuation) = AsyncThrowingStream<RealtimeSessionEvent, Error>.makeStream()

        self.events = events
        eventContinuation = continuation
        history = RealtimeHistory()
        currentAgent = agent
        self.model = model
        initialModelIdentifier = modelIdentifier ?? agent.model ?? "gpt-realtime"
    }

    public func connect() async throws {
        if TraceContext.currentTrace == nil {
            try await withTrace(name: "Realtime Session") {
                try await _connect()
            }
            return
        }

        try await _connect()
    }

    public func disconnect() async {
        let eventTask = eventTask
        self.eventTask = nil
        eventTask?.cancel()
        await model.disconnect()
        if let eventTask {
            await eventTask.value
        }

        isConnected = false
        activeResponses = 0
        pendingResponseRequests = 0
        pendingToolContinuations = 0
        resumeIdleWaitersIfPossible()
        finishEventStream()
    }

    public func sendMessage(_ text: String, previousItemID: String? = nil) async throws {
        try ensureConnected()
        lastServerError = nil

        let item = RealtimeConversationItem.message(.user(text: text))
        try await model.send(
            RealtimeConversationItemCreateEvent(
                previousItemId: previousItemID,
                item: item
            )
        )
        try await requestResponse()
    }

    public func sendAudio(_ data: Data, commit: Bool = true, requestResponse: Bool = true) async throws {
        try ensureConnected()
        lastServerError = nil

        try await model.send(RealtimeInputAudioBufferAppendEvent(audio: data.base64EncodedString()))

        if commit {
            try await model.send(RealtimeInputAudioBufferCommitEvent())
        }

        if requestResponse {
            try await self.requestResponse()
        }
    }

    public func requestResponse(_ response: RealtimeResponseCreate = RealtimeResponseCreate()) async throws {
        try ensureConnected()
        lastServerError = nil
        pendingResponseRequests += 1
        do {
            try await model.send(RealtimeResponseCreateEvent(response: response))
        } catch {
            pendingResponseRequests = max(0, pendingResponseRequests - 1)
            throw error
        }
    }

    public func cancelResponse() async throws {
        try ensureConnected()
        try await model.send(RealtimeResponseCancelEvent())
    }

    public func clearInputAudioBuffer() async throws {
        try ensureConnected()
        try await model.send(RealtimeInputAudioBufferClearEvent())
    }

    public func interruptPlayback(itemID: String, contentIndex: Int = 0, audioEndMilliseconds: Int) async throws {
        try ensureConnected()
        try await model.send(
            RealtimeConversationItemTruncateEvent(
                itemId: itemID,
                contentIndex: contentIndex,
                audioEndMs: audioEndMilliseconds
            )
        )
    }

    public func rebind(to agent: any RealtimeAgent) async throws {
        let requestedModel = agent.model ?? initialModelIdentifier
        guard requestedModel == initialModelIdentifier else {
            throw RealtimeSessionError.modelChangeRequiresNewSession(
                current: initialModelIdentifier,
                requested: requestedModel
            )
        }

        currentAgent = agent
        try await sendSessionUpdate(using: agent)
    }

    public func updateSession(_ configuration: RealtimeSessionConfiguration) async throws {
        let requestedModel = configuration.model ?? initialModelIdentifier
        guard requestedModel == initialModelIdentifier else {
            throw RealtimeSessionError.modelChangeRequiresNewSession(
                current: initialModelIdentifier,
                requested: requestedModel
            )
        }

        try ensureConnected()
        currentSessionConfiguration = configuration
        try await emitSessionUpdate(configuration.sendableUpdatePayload, agentName: currentAgent.name)
    }

    public func sendRaw(_ payload: [String: JSONValue]) async throws {
        try ensureConnected()
        try await model.sendRaw(payload)
    }

    public func waitUntilIdle() async throws {
        if let lastServerError, pendingResponseRequests == 0, activeResponses == 0, pendingToolContinuations == 0 {
            throw lastServerError
        }

        if pendingResponseRequests == 0, activeResponses == 0, pendingToolContinuations == 0 {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    public func historySnapshot() async -> [RealtimeConversationItem] {
        await history.snapshot()
    }

    private func _connect() async throws {
        guard !isConnected else {
            throw RealtimeSessionError.alreadyConnected
        }

        let stream = try await model.connect()
        isConnected = true

        eventTask = Task {
            do {
                for try await event in stream {
                    await handleServerEvent(event)
                }
                await finishEventStreamAsync()
            } catch {
                await finishEventStreamAsync(error: error)
            }
        }

        try await runWithOptionalSpan(
            name: "realtime.connect",
            data: [
                "agent": .string(currentAgent.name),
                "model": .string(initialModelIdentifier)
            ]
        ) {
            try await sendSessionUpdate(using: currentAgent)
        }
    }

    private func ensureConnected() throws {
        guard isConnected else {
            throw RealtimeSessionError.notConnected
        }
    }

    private func sendSessionUpdate(using agent: any RealtimeAgent) async throws {
        let configuration = try await resolvedSessionConfiguration(for: agent)
        currentSessionConfiguration = configuration
        try await emitSessionUpdate(configuration.sendableUpdatePayload, agentName: agent.name)
    }

    private func emitSessionUpdate(_ configuration: RealtimeSessionConfiguration, agentName: String) async throws {
        try await runWithOptionalSpan(
            name: "realtime.session_update",
            data: ["agent": .string(agentName)]
        ) {
            try await model.send(RealtimeSessionUpdateEvent(session: configuration))
        }
    }

    private func resolvedSessionConfiguration(for agent: any RealtimeAgent) async throws
        -> RealtimeSessionConfiguration {
        var configuration = agent.sessionConfiguration
        configuration.instructions = configuration.instructions ?? agent.instructions

        if configuration.maxOutputTokens == nil, let maxCompletionTokens = agent.modelSettings.maxCompletionTokens {
            configuration.maxOutputTokens = .finite(maxCompletionTokens)
        }

        if configuration.toolChoice == nil {
            configuration.toolChoice = agent.modelSettings.toolChoice
        }

        configuration.tools = try await resolvedRealtimeTools(for: agent)
        return configuration
    }

    private func resolvedRealtimeTools(for agent: any RealtimeAgent) async throws -> [Tool]? {
        var tools = [Tool]()
        var seenFunctionNames = Set<String>()
        let handoffToolNames = Set(agent.handoffs.map(\.toolName))

        func appendTool(_ tool: Tool) {
            guard tool.isRealtimeCompatible else {
                return
            }

            if case let .function(function) = tool {
                guard !handoffToolNames.contains(function.name) else {
                    return
                }

                guard seenFunctionNames.insert(function.name).inserted else {
                    return
                }
            }

            tools.append(tool)
        }

        for tool in agent.createTools() {
            appendTool(tool)
        }

        for proxy in agent.mcpServers {
            let listedTools = try await proxy.listTools()
            for listedTool in listedTools {
                let parameters: Parameters = if case let .object(object, _) = listedTool.inputSchema {
                    Parameters(properties: object.properties)
                } else {
                    .none
                }

                appendTool(
                    .function(
                        FunctionTool(
                            name: listedTool.name,
                            description: listedTool.description,
                            parameters: parameters,
                            strict: true
                        )
                    )
                )
            }
        }

        return tools.isEmpty ? nil : tools
    }

    private func handleServerEvent(_ event: RealtimeServerEvent) async {
        eventContinuation.yield(.raw(event))

        switch event.object {
            case let .sessionCreated(payload):
                currentSessionConfiguration = payload.session
                eventContinuation.yield(.sessionCreated(payload.session))

            case let .sessionUpdated(payload):
                currentSessionConfiguration = payload.session
                eventContinuation.yield(.sessionUpdated(payload.session))

            case let .conversationCreated(payload):
                conversationID = payload.conversation.id

            case let .conversationItemCreated(payload):
                await applyConversationItemEvent(payload)

            case let .conversationItemAdded(payload):
                await applyConversationItemEvent(payload)

            case let .conversationItemDone(payload):
                await applyConversationItemEvent(payload)

            case let .conversationItemDeleted(payload):
                if let change = await history.delete(itemID: payload.itemId) {
                    eventContinuation.yield(.historyChange(change))
                }

            case let .conversationItemTruncated(payload):
                if let change = await history.applyTruncation(
                    itemID: payload.itemId,
                    contentIndex: payload.contentIndex,
                    audioEndMilliseconds: payload.audioEndMs
                ) {
                    eventContinuation.yield(.historyChange(change))
                }

            case let .conversationItemInputAudioTranscriptionDelta(payload):
                eventContinuation.yield(.inputAudioTranscriptDelta(payload))

            case let .conversationItemInputAudioTranscriptionCompleted(payload):
                if let change = await history.applyInputAudioTranscript(
                    itemID: payload.itemId,
                    contentIndex: payload.contentIndex,
                    transcript: payload.transcript
                ) {
                    eventContinuation.yield(.historyChange(change))
                }
                eventContinuation.yield(.inputAudioTranscriptDone(payload))
                await recordTranscriptionSpan(transcript: payload.transcript)

            case .responseCreated:
                pendingResponseRequests = max(0, pendingResponseRequests - 1)
                activeResponses += 1

            case let .responseDone(payload):
                await handleResponseDone(payload)

            case let .responseOutputItemAdded(payload):
                if let change = await history.upsert(payload.item) {
                    eventContinuation.yield(.historyChange(change))
                }

            case let .responseOutputItemDone(payload):
                if let change = await history.upsert(payload.item) {
                    eventContinuation.yield(.historyChange(change))
                }
                if case let .functionCall(call) = payload.item {
                    eventContinuation.yield(.toolCalled(call))
                }

            case let .responseOutputTextDelta(payload):
                eventContinuation.yield(.textDelta(payload))

            case let .responseOutputTextDone(payload):
                eventContinuation.yield(.textDone(payload))

            case let .responseOutputAudioDelta(payload):
                eventContinuation.yield(.audioDelta(payload))

            case let .responseOutputAudioDone(payload):
                eventContinuation.yield(.audioDone(payload))
                await recordSpeechSpan(byteCount: payload.audio?.count)

            case let .responseOutputAudioTranscriptDelta(payload):
                eventContinuation.yield(.outputAudioTranscriptDelta(payload))

            case let .responseOutputAudioTranscriptDone(payload):
                eventContinuation.yield(.outputAudioTranscriptDone(payload))

            case .responseFunctionCallArgumentsDelta:
                break

            case .responseFunctionCallArgumentsDone:
                break

            case let .error(payload):
                let error = APIError.apiError(payload.error.message)
                lastServerError = error
                pendingResponseRequests = 0
                eventContinuation.yield(.error(payload.error))
                failIdleWaiters(error)

            case .unknown:
                break
        }
    }

    private func applyConversationItemEvent(_ payload: RealtimeServerEvent.ConversationItemEvent) async {
        if let change = await history.upsert(payload.item, previousItemID: payload.previousItemId) {
            eventContinuation.yield(.historyChange(change))
        }
    }

    private func handleResponseDone(_ payload: RealtimeServerEvent.ResponseEvent) async {
        for item in payload.response.output ?? [] {
            if let change = await history.upsert(item) {
                eventContinuation.yield(.historyChange(change))
            }
        }

        let functionCalls = payload.response.output?.compactMap { item -> OutputItem.FunctionCall? in
            if case let .functionCall(functionCall) = item {
                return functionCall
            }
            return nil
        } ?? []

        if !functionCalls.isEmpty {
            pendingToolContinuations += 1
        }

        activeResponses = max(0, activeResponses - 1)
        eventContinuation.yield(.responseCompleted(payload.response))

        if !functionCalls.isEmpty {
            let agent = currentAgent
            Task {
                await self.executeAndContinue(functionCalls, using: agent)
            }
        }

        resumeIdleWaitersIfPossible()
    }

    private func executeAndContinue(_ functionCalls: [OutputItem.FunctionCall], using agent: any RealtimeAgent) async {
        defer {
            pendingToolContinuations = max(0, pendingToolContinuations - 1)
            resumeIdleWaitersIfPossible()
        }

        do {
            let outputs = try await agent.executeToolCalls(functionCalls)

            for output in outputs {
                if case let .functionCallOutput(functionCallOutput) = output {
                    eventContinuation.yield(.toolOutput(functionCallOutput))
                    try await model.send(
                        RealtimeConversationItemCreateEvent(
                            item: .functionCallOutput(functionCallOutput)
                        )
                    )
                }
            }

            pendingResponseRequests += 1
            try await model.send(RealtimeResponseCreateEvent())
        } catch {
            lastServerError = error
            pendingResponseRequests = max(0, pendingResponseRequests - 1)
            let detail = ErrorDetail(
                message: error.localizedDescription,
                type: "tool_execution_error",
                param: nil,
                code: nil
            )
            eventContinuation.yield(.error(detail))
            failIdleWaiters(error)
        }
    }

    private func resumeIdleWaitersIfPossible() {
        guard pendingResponseRequests == 0, activeResponses == 0, pendingToolContinuations == 0 else {
            return
        }

        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func failIdleWaiters(_ error: Error) {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func finishEventStream() {
        guard !hasFinished else {
            return
        }

        hasFinished = true
        eventContinuation.finish()
    }

    private func finishEventStreamAsync(error: Error? = nil) async {
        guard !hasFinished else {
            return
        }

        hasFinished = true
        isConnected = false
        activeResponses = 0
        pendingResponseRequests = 0
        pendingToolContinuations = 0

        if let error {
            lastServerError = error
            failIdleWaiters(error)
            eventContinuation.finish(throwing: error)
        } else {
            resumeIdleWaitersIfPossible()
            eventContinuation.finish()
        }
    }

    private func recordTranscriptionSpan(transcript: String) async {
        let transcriptionModel = currentSessionConfiguration?.audio?.input?.transcription?.model
        try? await runWithOptionalTraceSpan(
            spanData: TranscriptionSpanData(output: transcript, model: transcriptionModel)
        )
    }

    private func recordSpeechSpan(byteCount: Int?) async {
        let outputFormat = currentSessionConfiguration?.audio?.output?.format?.type
        let output = byteCount.map { "\($0) bytes" }
        try? await runWithOptionalTraceSpan(
            spanData: SpeechSpanData(output: output, outputFormat: outputFormat, model: initialModelIdentifier)
        )
    }

    private func runWithOptionalSpan<T>(
        name: String,
        data: [String: JSONValue] = [:],
        operation: () async throws -> T
    ) async throws -> T {
        guard TraceContext.currentTrace != nil else {
            return try await operation()
        }

        return try await withSpan(spanData: CustomSpanData(name: name, data: data)) { _ in
            try await operation()
        }
    }

    private func runWithOptionalTraceSpan(spanData: SpanData) async throws {
        guard TraceContext.currentTrace != nil else {
            return
        }

        try await withSpan(spanData: spanData) { _ in
        }
    }
}
