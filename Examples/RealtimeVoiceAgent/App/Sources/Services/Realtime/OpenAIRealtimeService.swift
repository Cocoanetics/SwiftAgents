import Foundation
import Providers
import SwiftMCP

/// Thin adapter over the package's `RealtimeSession`. Responsibilities:
///   - Auth resolution (embedded API key or token-endpoint fetch).
///   - Mapping the package's typed `RealtimeSessionEvent` stream to RVA's
///     `RealtimeServiceEvent` so the UI layer doesn't change.
///   - Tracking call_id → tool name so the "hangup" tool can trigger
///     `.hangupRequested` after it runs (`FunctionCallOutput` carries the id
///     but not the name).
///   - Persisting conversation history to a JSONL file in Documents.
actor OpenAIRealtimeService {
    enum ServiceError: LocalizedError {
        case missingCredentials
        case invalidTokenPayload

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "Missing realtime credentials."
            case .invalidTokenPayload:
                return "The token endpoint did not return a usable token."
            }
        }
    }

    nonisolated let events: AsyncStream<RealtimeServiceEvent>

    private let configuration: AppConfiguration
    private let toolRegistry: LocalToolRegistry
    private let eventContinuation: AsyncStream<RealtimeServiceEvent>.Continuation

    private var session: RealtimeSession?
    private var sessionEventTask: Task<Void, Never>?
    private var pendingToolNames: [String: String] = [:]
    private var currentAudioItemID: String?
    private var currentAudioContentIndex: Int = 0

    init(configuration: AppConfiguration, toolRegistry: LocalToolRegistry) {
        self.configuration = configuration
        self.toolRegistry = toolRegistry

        var continuation: AsyncStream<RealtimeServiceEvent>.Continuation!
        events = AsyncStream<RealtimeServiceEvent> { c in continuation = c }
        eventContinuation = continuation
    }

    // MARK: - Lifecycle

    func connect() async throws {
        guard session == nil else { return }

        eventContinuation.yield(.state(.connecting))

        let token = try await resolveAuthToken()
        eventContinuation.yield(.log("Opening realtime session for model \(configuration.model)."))
        eventContinuation.yield(.log("Auth mode: \(configuration.authModeDescription)"))

        let agent = RVARealtimeAgent(configuration: configuration, toolRegistry: toolRegistry)
        let model = OpenAIRealtimeWebSocketModel(
            openAI: OpenAI(apiKey: token),
            model: configuration.model
        )
        let session = RealtimeSession(agent: agent, model: model, modelIdentifier: configuration.model)
        self.session = session

        sessionEventTask = Task { [weak self] in
            await self?.consumeEvents(from: session)
        }

        do {
            try await session.connect()
        } catch {
            self.session = nil
            sessionEventTask?.cancel()
            sessionEventTask = nil
            eventContinuation.yield(.state(.failed(error.localizedDescription)))
            throw error
        }

        let vadMode = configuration.useServerVAD ? "semantic_vad" : "manual"
        eventContinuation.yield(
            .log("Realtime session ready: voice=\(configuration.voice), VAD=\(vadMode).")
        )
    }

    func disconnect() async {
        eventContinuation.yield(.state(.disconnecting))
        sessionEventTask?.cancel()
        sessionEventTask = nil
        if let session {
            await session.disconnect()
        }
        session = nil
        pendingToolNames.removeAll()
        currentAudioItemID = nil
        eventContinuation.yield(.state(.disconnected))
    }

    // MARK: - Outbound

    func appendInputAudioChunk(_ data: Data) async {
        guard let session else { return }
        do {
            // commit=false because server VAD handles segmentation; requestResponse=false
            // because server VAD also auto-requests responses on speech_stopped.
            try await session.sendAudio(data, commit: false, requestResponse: false)
        } catch {
            eventContinuation.yield(.log("Failed to send input audio: \(error.localizedDescription)"))
        }
    }

    func cancelCurrentResponse() async {
        guard let session else { return }
        do {
            try await session.cancelResponse()
            eventContinuation.yield(.log("Sent response.cancel."))
        } catch {
            eventContinuation.yield(.log("Failed to cancel response: \(error.localizedDescription)"))
        }
    }

    func truncateItem(id: String, contentIndex: Int, audioEndMs: Int) async {
        guard let session else { return }
        do {
            try await session.interruptPlayback(
                itemID: id,
                contentIndex: contentIndex,
                audioEndMilliseconds: audioEndMs
            )
            eventContinuation.yield(.log("Sent conversation.item.truncate for \(id) at \(audioEndMs) ms."))
        } catch {
            eventContinuation.yield(.log("Failed to truncate item: \(error.localizedDescription)"))
        }
        currentAudioItemID = nil
    }

    /// Current session history items — forwards to the underlying
    /// `RealtimeSession.historySnapshot()`. Used by the ViewModel for
    /// persisting conversation history via `RealtimeHistory.save(_:to:)`.
    func historySnapshot() async -> [RealtimeConversationItem] {
        guard let session else { return [] }
        return await session.historySnapshot()
    }

    // MARK: - Inbound

    private func consumeEvents(from session: RealtimeSession) async {
        let stream = await session.events
        do {
            for try await event in stream {
                handle(event)
            }
        } catch {
            eventContinuation.yield(.log("Realtime socket closed: \(error.localizedDescription)"))
            eventContinuation.yield(.state(.failed(error.localizedDescription)))
        }
    }

    private func handle(_ event: RealtimeSessionEvent) {
        switch event {
        case .sessionCreated, .sessionUpdated:
            eventContinuation.yield(.state(.connected))
            if configuration.realtimeTokenEndpoint == nil, configuration.apiKey != nil {
                eventContinuation.yield(.log(
                    "Using a bundled API key. Replace it with a backend-issued ephemeral token before shipping."
                ))
            }

        case let .audioDelta(payload):
            currentAudioItemID = payload.itemId
            currentAudioContentIndex = payload.contentIndex
            if let data = payload.delta {
                eventContinuation.yield(.audioOutput(AudioChunk(
                    data: data,
                    itemID: payload.itemId,
                    contentIndex: payload.contentIndex
                )))
            }

        case let .inputAudioTranscriptDelta(payload):
            emitTranscript(itemID: payload.itemId, role: .user, text: payload.delta, isFinal: false, replace: false)

        case let .inputAudioTranscriptDone(payload):
            emitTranscript(itemID: payload.itemId, role: .user, text: payload.transcript, isFinal: true, replace: true)

        case let .outputAudioTranscriptDelta(payload):
            emitTranscript(itemID: payload.itemId, role: .assistant, text: payload.delta, isFinal: false, replace: false)

        case let .outputAudioTranscriptDone(payload):
            emitTranscript(itemID: payload.itemId, role: .assistant, text: payload.transcript, isFinal: true, replace: true)

        case let .textDelta(payload):
            emitTranscript(itemID: payload.itemId, role: .assistant, text: payload.delta, isFinal: false, replace: false)

        case let .textDone(payload):
            emitTranscript(itemID: payload.itemId, role: .assistant, text: payload.text, isFinal: true, replace: true)

        case let .toolCalled(call):
            pendingToolNames[call.callId] = call.name
            eventContinuation.yield(.toolCallBegan)
            eventContinuation.yield(.transcript(.init(
                itemID: "tool-\(call.callId)",
                role: .tool,
                text: "Running \(call.name)…",
                isFinal: false,
                replace: true
            )))
            eventContinuation.yield(.log("Tool call requested: \(call.name) args=\(call.arguments)"))

        case let .toolOutput(output):
            let name = pendingToolNames.removeValue(forKey: output.callId) ?? "tool"
            let displayText = name == output.output ? output.output : "\(name): \(output.output)"
            eventContinuation.yield(.transcript(.init(
                itemID: "tool-\(output.callId)",
                role: .tool,
                text: displayText,
                isFinal: true,
                replace: true
            )))
            eventContinuation.yield(.log("Tool result ready: \(name) -> \(output.output)"))
            if name == "hangup" {
                eventContinuation.yield(.hangupRequested)
            }

        case .responseCompleted:
            eventContinuation.yield(.responseActive(false))
            eventContinuation.yield(.flushPlayback)

        case let .error(detail):
            let code = detail.code.map { " [\($0)]" } ?? ""
            eventContinuation.yield(.log("Realtime error\(code): \(detail.message)"))
            if detail.code == "response_cancel_not_active" {
                eventContinuation.yield(.log("Ignoring benign cancel error (no assistant response in flight)."))
            } else {
                eventContinuation.yield(.state(.failed(detail.message)))
            }

        case .inputSpeechStarted:
            eventContinuation.yield(.userSpeechDetected(true))
            let interrupt = PlaybackInterrupt(
                itemID: currentAudioItemID ?? "",
                contentIndex: currentAudioContentIndex
            )
            eventContinuation.yield(.interruptPlayback(interrupt))
            Task { await self.cancelCurrentResponse() }

        case .inputSpeechStopped:
            eventContinuation.yield(.userSpeechDetected(false))

        case let .raw(server):
            // response.created isn't yet surfaced as a typed event — read it
            // off the raw stream so the UI can flip into "responseActive".
            if server.type == "response.created" {
                eventContinuation.yield(.responseActive(true))
            }

        case .audioDone, .historyChange:
            break
        }
    }

    private func emitTranscript(
        itemID: String,
        role: TranscriptRole,
        text: String,
        isFinal: Bool,
        replace: Bool
    ) {
        guard !text.isEmpty else { return }
        eventContinuation.yield(.transcript(.init(
            itemID: itemID,
            role: role,
            text: text,
            isFinal: isFinal,
            replace: replace
        )))
    }

    // MARK: - Auth

    private func resolveAuthToken() async throws -> String {
        if let endpoint = configuration.realtimeTokenEndpoint {
            let (data, response) = try await URLSession.shared.data(from: endpoint)

            if let httpResponse = response as? HTTPURLResponse, !(200 ..< 300).contains(httpResponse.statusCode) {
                throw ServiceError.invalidTokenPayload
            }

            if let rawToken = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !rawToken.isEmpty,
               !rawToken.hasPrefix("{") {
                return rawToken
            }

            let payload = try JSONDecoder().decode(JSONValue.self, from: data)
            if let token = payload["client_secret"]?["value"]?.stringValue
                ?? payload["value"]?.stringValue
                ?? payload["token"]?.stringValue {
                return token
            }

            throw ServiceError.invalidTokenPayload
        }

        if let apiKey = configuration.apiKey {
            eventContinuation.yield(.log("Using embedded API key for realtime auth."))
            return apiKey
        }

        throw ServiceError.missingCredentials
    }

}
