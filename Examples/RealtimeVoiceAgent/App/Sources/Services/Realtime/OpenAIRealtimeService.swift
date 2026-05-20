import Foundation
import SwiftMCP

actor OpenAIRealtimeService {
    enum ServiceError: LocalizedError {
        case missingCredentials
        case invalidTokenPayload
        case invalidWebSocketURL

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "Missing realtime credentials."
            case .invalidTokenPayload:
                return "The token endpoint did not return a usable token."
            case .invalidWebSocketURL:
                return "The realtime WebSocket URL is invalid."
            }
        }
    }

    nonisolated let events: AsyncStream<RealtimeServiceEvent>

    private let configuration: AppConfiguration
    private let toolRegistry: LocalToolRegistry
    private let transport = RealtimeTransport()
    private let eventContinuation: AsyncStream<RealtimeServiceEvent>.Continuation

    private var receiveTask: Task<Void, Never>?
    private var isConnected = false
    private var hasActiveResponse = false
    private var currentAudioItemID: String?
    private var currentAudioContentIndex: Int = 0

    init(configuration: AppConfiguration, toolRegistry: LocalToolRegistry) {
        self.configuration = configuration
        self.toolRegistry = toolRegistry

        var continuation: AsyncStream<RealtimeServiceEvent>.Continuation!
        self.events = AsyncStream<RealtimeServiceEvent> { streamContinuation in
            continuation = streamContinuation
        }
        self.eventContinuation = continuation
    }

    func connect() async throws {
        guard receiveTask == nil else { return }

        eventContinuation.yield(.state(.connecting))

        let token = try await resolveAuthToken()
        let socketURL = try socketURL()
        eventContinuation.yield(.log("Opening realtime socket: \(socketURL.absoluteString)"))
        eventContinuation.yield(.log("Auth mode: \(configuration.realtimeTokenEndpoint != nil ? "ephemeral token" : "embedded API key")"))

        await transport.connect(
            url: socketURL,
            headers: [
                "Authorization": "Bearer \(token)"
            ]
        )

        receiveTask = Task {
            await self.receiveLoop()
        }

        try await sendSessionUpdate()
        let vadMode = configuration.useServerVAD ? "semantic_vad (eagerness: high)" : "manual"
        eventContinuation.yield(.log("Sent session.update for model \(configuration.model), voice \(configuration.voice), VAD \(vadMode)."))

        // try await replayConversationHistory()
    }

    func disconnect() async {
        eventContinuation.yield(.state(.disconnecting))
        receiveTask?.cancel()
        receiveTask = nil
        await transport.disconnect()
        isConnected = false
        eventContinuation.yield(.state(.disconnected))
    }

    func appendInputAudioChunk(_ data: Data) async {
        guard isConnected else { return }

        do {
            try await transport.send(.object([
                "type": .string("input_audio_buffer.append"),
                "audio": .string(data.base64EncodedString())
            ]))
        } catch {
            eventContinuation.yield(.log("Failed to send input audio: \(error.localizedDescription)"))
        }
    }

    func cancelCurrentResponse() async {
        guard isConnected, hasActiveResponse else { return }

        do {
            try await transport.send(.object(["type": .string("response.cancel")]))
            eventContinuation.yield(.log("Sent response.cancel for active response."))
        } catch {
            eventContinuation.yield(.log("Failed to cancel response: \(error.localizedDescription)"))
        }
    }

    func truncateItem(id: String, contentIndex: Int, audioEndMs: Int) async {
        guard isConnected else { return }

        do {
            try await transport.send(.object([
                "type": .string("conversation.item.truncate"),
                "item_id": .string(id),
                "content_index": .integer(contentIndex),
                "audio_end_ms": .integer(audioEndMs)
            ]))
            eventContinuation.yield(.log("Sent conversation.item.truncate for \(id) at \(audioEndMs) ms."))
        } catch {
            eventContinuation.yield(.log("Failed to truncate item: \(error.localizedDescription)"))
        }
        currentAudioItemID = nil
    }

    private func socketURL() throws -> URL {
        guard var components = URLComponents(url: configuration.realtimeWebSocketURL, resolvingAgainstBaseURL: false) else {
            throw ServiceError.invalidWebSocketURL
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "model" }
        queryItems.append(URLQueryItem(name: "model", value: configuration.model))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw ServiceError.invalidWebSocketURL
        }

        return url
    }

    private func sendSessionUpdate() async throws {
        let tools = await toolRegistry.realtimeToolPayloads()

        let session = JSONValue.object([
            "type": .string("realtime"),
            "model": .string(configuration.model),
            "instructions": .string(configuration.instructions),
            "output_modalities": .array([.string("audio")]),
            "audio": .object([
                "input": .object([
                    "format": .object([
                        "type": .string("audio/pcm"),
                        "rate": .integer(24_000)
                    ]),
                    "noise_reduction": .object([
                        "type": .string("near_field")
                    ]),
                    "transcription": .object([
                        "model": .string(configuration.transcriptionModel)
                    ]),
                    "turn_detection": configuration.useServerVAD
                        ? .object([
                            "type": .string("semantic_vad"),
                            "create_response": .bool(true),
                            "interrupt_response": .bool(true),
                            "eagerness": .string("high")
                        ])
                        : .null
                ]),
                "output": .object([
                    "format": .object([
                        "type": .string("audio/pcm"),
                        "rate": .integer(24_000)
                    ]),
                    "voice": .string(configuration.voice)
                ])
            ]),
            "tool_choice": .string("auto"),
            "tools": .array(tools)
        ])

        try await transport.send(.object([
            "type": .string("session.update"),
            "session": session
        ]))
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                let event = try await transport.receive()
                await handleServerEvent(event)
            } catch {
                guard !Task.isCancelled else { break }

                isConnected = false
                hasActiveResponse = false
                eventContinuation.yield(.responseActive(false))
                eventContinuation.yield(.state(.failed(error.localizedDescription)))
                eventContinuation.yield(.log("Realtime socket closed: \(error.localizedDescription)"))
                await transport.disconnect()
                receiveTask = nil
                break
            }
        }
    }

    private func handleServerEvent(_ event: JSONValue) async {
        guard let type = event["type"]?.stringValue else { return }

        if shouldLog(eventType: type) {
            eventContinuation.yield(.log("Realtime event: \(type)"))
        }

        switch type {
        case "session.created", "session.updated":
            isConnected = true
            eventContinuation.yield(.state(.connected))
            if type == "session.created", configuration.realtimeTokenEndpoint == nil, configuration.apiKey != nil {
                eventContinuation.yield(.log("Using a bundled API key. Replace it with a backend-issued ephemeral token before shipping."))
            }

        case "response.created":
            hasActiveResponse = true
            eventContinuation.yield(.responseActive(true))
            if let responseID = event["response"]?["id"]?.stringValue {
                eventContinuation.yield(.log("Response created: \(responseID)"))
            }

        case "conversation.item.input_audio_transcription.delta":
            emitTranscript(
                from: event,
                role: .user,
                textKey: "delta",
                isFinal: false,
                replace: false
            )

        case "conversation.item.input_audio_transcription.completed":
            emitTranscript(
                from: event,
                role: .user,
                textKey: "transcript",
                isFinal: true,
                replace: true
            )

        case "conversation.item.input_audio_transcription.failed":
            eventContinuation.yield(.log("Input transcription failed."))

        case "input_audio_buffer.speech_started":
            eventContinuation.yield(.userSpeechDetected(true))
            if let itemID = currentAudioItemID {
                eventContinuation.yield(.interruptPlayback(PlaybackInterrupt(itemID: itemID, contentIndex: currentAudioContentIndex)))
            } else {
                eventContinuation.yield(.interruptPlayback(PlaybackInterrupt(itemID: "", contentIndex: 0)))
            }
            await cancelCurrentResponse()

        case "input_audio_buffer.speech_stopped":
            eventContinuation.yield(.userSpeechDetected(false))

        case "response.output_audio.delta":
            if let payload = event["delta"]?.stringValue, let data = Data(base64Encoded: payload) {
                let itemID = event["item_id"]?.stringValue ?? ""
                let contentIndex = event["content_index"]?.intValue ?? 0
                currentAudioItemID = itemID
                currentAudioContentIndex = contentIndex
                eventContinuation.yield(.audioOutput(AudioChunk(data: data, itemID: itemID, contentIndex: contentIndex)))
            }

        case "response.output_audio_transcript.delta":
            emitTranscript(
                from: event,
                role: .assistant,
                textKey: "delta",
                isFinal: false,
                replace: false
            )

        case "response.output_audio_transcript.done":
            emitTranscript(
                from: event,
                role: .assistant,
                textKey: "transcript",
                isFinal: true,
                replace: true
            )

        case "response.output_text.delta":
            emitTranscript(
                from: event,
                role: .assistant,
                textKey: "delta",
                isFinal: false,
                replace: false
            )

        case "response.output_text.done":
            emitTranscript(
                from: event,
                role: .assistant,
                textKey: "text",
                isFinal: true,
                replace: true
            )

        case "response.function_call_arguments.done":
            await handleFunctionCall(event)

        case "response.done":
            hasActiveResponse = false
            currentAudioItemID = nil
            eventContinuation.yield(.responseActive(false))
            eventContinuation.yield(.flushPlayback)
            if let status = event["response"]?["status"]?.stringValue {
                eventContinuation.yield(.log("Response finished with status: \(status)"))
            }

        case "error":
            let message = event["error"]?["message"]?.stringValue ?? "Unknown realtime error."
            let code = event["error"]?["code"]?.stringValue
            let details = (try? String(data: JSONEncoder().encode(event), encoding: .utf8)) ?? "<unavailable>"
            eventContinuation.yield(.log("Realtime error\(code.map { " [\($0)]" } ?? ""): \(message)"))
            eventContinuation.yield(.log("Error payload: \(details)"))
            if code == "response_cancel_not_active" {
                eventContinuation.yield(.log("Ignoring benign cancel error because no assistant response was in flight."))
            } else {
                eventContinuation.yield(.state(.failed(message)))
            }

        case "conversation.item.truncated":
            let truncatedItemID = event["item_id"]?.stringValue ?? "unknown"
            let audioEndMs = event["audio_end_ms"]?.intValue ?? 0
            eventContinuation.yield(.log("Server confirmed truncation of \(truncatedItemID) at \(audioEndMs) ms."))

        default:
            if let summary = summarizedEvent(event, type: type) {
                eventContinuation.yield(.log(summary))
            }
        }
    }

    private func emitTranscript(from event: JSONValue, role: TranscriptRole, textKey: String, isFinal: Bool, replace: Bool) {
        guard let text = event[textKey]?.stringValue, !text.isEmpty else { return }

        let itemID = event["item_id"]?.stringValue
            ?? "\(role.rawValue)-\(event["response_id"]?.stringValue ?? UUID().uuidString)-\(event["content_index"]?.intValue ?? 0)"

        eventContinuation.yield(.transcript(.init(
            itemID: itemID,
            role: role,
            text: text,
            isFinal: isFinal,
            replace: replace
        )))
    }

    private func handleFunctionCall(_ event: JSONValue) async {
        guard let name = event["name"]?.stringValue,
              let callID = event["call_id"]?.stringValue else {
            return
        }

        let arguments = event["arguments"]?.stringValue ?? "{}"

        eventContinuation.yield(.transcript(.init(
            itemID: "tool-\(callID)",
            role: .tool,
            text: "Running \(name)…",
            isFinal: false,
            replace: true
        )))
        eventContinuation.yield(.log("Tool call requested: \(name) args=\(arguments)"))
        eventContinuation.yield(.toolCallBegan)

        let result = await toolRegistry.execute(name: name, argumentsJSONString: arguments)

        // Handle hangup specially — signal the ViewModel to end the call
        // after playback finishes, but still send the tool output so the
        // model can generate a farewell if it hasn't already.
        let isHangup = (name == "hangup")

        let fullOutputString = String(describing: result.output)
        eventContinuation.yield(.transcript(.init(
            itemID: "tool-\(callID)",
            role: .tool,
            text: "\(name): \(result.summary)",
            fullOutput: fullOutputString != result.summary ? fullOutputString : nil,
            isFinal: true,
            replace: true
        )))

        do {
            eventContinuation.yield(.log("Tool result ready: \(name) -> \(result.summary)"))
            try await transport.send(.object([
                "type": .string("conversation.item.create"),
                "item": .object([
                    "type": .string("function_call_output"),
                    "call_id": .string(callID),
                    "output": .string(String(data: try JSONEncoder().encode(result.output), encoding: .utf8) ?? "{}")
                ])
            ]))

            if !isHangup {
                try await transport.send(.object([
                    "type": .string("response.create"),
                    "response": .object([:])
                ]))
            }
        } catch {
            eventContinuation.yield(.log("Failed to return tool output: \(error.localizedDescription)"))
        }

        if isHangup {
            eventContinuation.yield(.hangupRequested)
        }
    }

    // MARK: - Conversation History (JSONL)

    /// Loads saved conversation turns as `TranscriptEntry` values for display in the UI.
    static func loadTranscriptEntries() -> [TranscriptEntry] {
        let url = historyFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        var entries: [TranscriptEntry] = []

        for (index, line) in lines.enumerated() {
            guard let lineData = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(JSONValue.self, from: lineData),
                  let item = event["item"],
                  let roleString = item["role"]?.stringValue,
                  let content = item["content"]?.arrayValue,
                  let text = content.first?["text"]?.stringValue else { continue }

            let role: TranscriptRole
            let displayText: String
            if roleString == "assistant" {
                role = .assistant
                displayText = text
            } else if text.hasPrefix("[tool] ") {
                role = .tool
                displayText = String(text.dropFirst(7))
            } else {
                role = .user
                displayText = text
            }

            entries.append(TranscriptEntry(
                id: "history-\(index)",
                sourceItemIDs: ["history-\(index)"],
                role: role,
                text: displayText,
                isFinal: true,
                updatedAt: .distantPast
            ))
        }

        return entries
    }

    private static var historyFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("conversation_history.jsonl")
    }

    private func replayConversationHistory() async throws {
        let url = Self.historyFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else {
            return
        }

        let lines = String(data: data, encoding: .utf8)?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        eventContinuation.yield(.log("Replaying \(lines.count) conversation turns from \(url.lastPathComponent)."))

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(JSONValue.self, from: lineData) else { continue }
            try await transport.send(event)
        }

        eventContinuation.yield(.log("Conversation history replayed."))
    }

    /// Writes the full conversation history to the JSONL file, replacing any previous content.
    /// Tool turns are stored as user messages prefixed with `[tool] ` so the model gets context.
    static func saveHistory(turns: [(role: String, text: String)]) {
        let encoder = JSONEncoder()
        var lines = ""

        for turn in turns {
            let apiRole: String
            let contentType: String
            let text: String

            switch turn.role {
            case "assistant":
                apiRole = "assistant"
                contentType = "output_text"
                text = turn.text
            case "tool":
                // The Realtime API doesn't support replaying tool items,
                // so store as a user message with a marker.
                apiRole = "user"
                contentType = "input_text"
                text = "[tool] \(turn.text)"
            default:
                apiRole = "user"
                contentType = "input_text"
                text = turn.text
            }

            let event = JSONValue.object([
                "type": .string("conversation.item.create"),
                "item": .object([
                    "type": .string("message"),
                    "role": .string(apiRole),
                    "content": .array([
                        .object([
                            "type": .string(contentType),
                            "text": .string(text)
                        ])
                    ])
                ])
            ])

            if let data = try? encoder.encode(event),
               let line = String(data: data, encoding: .utf8) {
                lines += line + "\n"
            }
        }

        try? lines.write(to: historyFileURL, atomically: true, encoding: .utf8)
    }

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

    private func shouldLog(eventType: String) -> Bool {
        switch eventType {
        case "session.created",
             "session.updated",
             "input_audio_buffer.speech_started",
             "input_audio_buffer.speech_stopped",
             "response.created",
             "response.done",
             "response.output_audio.delta",
             "response.output_audio_transcript.delta",
             "response.output_audio_transcript.done",
             "response.function_call_arguments.done",
             "conversation.item.input_audio_transcription.delta",
             "conversation.item.input_audio_transcription.completed":
            return true
        default:
            return false
        }
    }

    private func summarizedEvent(_ event: JSONValue, type: String) -> String? {
        switch type {
        case "rate_limits.updated":
            return "Rate limits updated."
        case "response.failed":
            return "Response failed: \(event["response"]?["status_details"]?.stringValue ?? event["response"]?["status"]?.stringValue ?? "unknown")"
        default:
            return nil
        }
    }
}
