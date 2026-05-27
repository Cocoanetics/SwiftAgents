import CallKit
import OSLog
import SwiftAgents
import SwiftUI

@MainActor
final class ConversationViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "RealtimeVoiceAgent", category: "Conversation")
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var transcriptEntries: [TranscriptEntry] = []
    @Published private(set) var statusMessages: [String] = []
    @Published private(set) var documentsPath: String = ""
    @Published private(set) var documentsURL: URL?
    @Published private(set) var isAwaitingUserTranscript = false
    @Published private(set) var preferredOutputRoute: AudioSessionController.OutputRoute = .phone
    @Published private(set) var currentOutputRoute: AudioSessionController.OutputRoute = .phone
    @Published private(set) var usesSystemRouteControls = false
    @Published var showFileContent: ShowFileContent?

    let configuration: AppConfiguration

    private let backgroundTaskController = BackgroundTaskController()
    private let audioCoordinator = AudioStreamCoordinator()
    private let spokenTextTracker = SpokenTextTracker()
    private let toolRegistry: LocalToolRegistry
    private let callKitController: CallKitController
    private let isUITestCallKitMode: Bool

    private var session: RealtimeSession?
    private var eventsTask: Task<Void, Never>?
    private var activeUserPlaceholderID: String?
    private var pendingUserInsertionIndex: Int?
    private var isSceneInBackground = false
    private var hasActiveAssistantResponse = false
    private var playbackSyncTask: Task<Void, Never>?
    private var truncatedItemIDs: Set<String> = []
    private var pendingHangup = false
    private var isConversationSessionConfigured = false
    private var isCallKitAudioSessionActivated = false
    private var hasStartedAudioEngine = false
    /// Tracks `call_id` → tool name so the `hangup` tool can trigger
    /// `pendingHangup` after its result lands (`FunctionCallOutput` has only
    /// the call id, not the name).
    private var pendingToolNames: [String: String] = [:]
    /// Latest assistant-audio item id and content index — captured from
    /// `.audioDelta` so user barge-in can truncate the right item.
    private var currentAudioItemID: String?
    private var currentAudioContentIndex: Int = 0

    init(
        configuration: AppConfiguration,
        isUITestCallKitMode: Bool = false,
        callKitController: CallKitController = CallKitController(),
        startCallRouter: StartCallRouter? = nil
    ) {
        self.configuration = configuration
        self.isUITestCallKitMode = isUITestCallKitMode
        self.callKitController = callKitController
        let toolRegistry = LocalToolRegistry(
            openclawEndpoint: configuration.openclawEndpoint,
            openclawToken: configuration.openclawToken
        )
        self.toolRegistry = toolRegistry

        // --- CallKit lifecycle (matches Apple's Speakerbox sample) ---
        //
        // Phase 1 – CXStartCallAction: connect WebSocket + configure audio session.
        //           Do NOT start the audio engine yet.
        callKitController.onStartCallRequested = { [weak self] in
            try await self?.configureConversationSession()
        }
        // Phase 2 – didActivate: system has elevated the audio session priority.
        //           NOW start the audio engine.
        callKitController.onAudioSessionActivated = { [weak self] in
            self?.handleCallKitAudioSessionActivated()
        }
        // End call – CXEndCallAction: stop audio + disconnect.
        callKitController.onEndCallRequested = { [weak self] in
            await self?.stopConversationSession()
        }
        callKitController.onAudioSessionDeactivated = { [weak self] in
            self?.appendStatus("CallKit deactivated audio session.")
        }

        audioCoordinator.onRouteChanged = { [weak self] in
            guard let self else { return }
            self.currentOutputRoute = self.audioCoordinator.currentOutputRoute
        }

        audioCoordinator.onRouteChangeStatus = { [weak self] message in
            self?.appendStatus(message)
        }

        startCallRouter?.onStartCallRequested = { [weak self] handle in
            Task { @MainActor [weak self] in
                await self?.startConversation(handle: handle)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            let docsURL = await toolRegistry.documentsURL
            self.documentsPath = docsURL.path
            self.documentsURL = docsURL
        }

        Task { [weak self] in
            guard let self else { return }
            await toolRegistry.setShowFileHandler { [weak self] title, content in
                self?.showFileContent = ShowFileContent(title: title, content: content)
            }
        }
    }

    var canStart: Bool {
        configuration.startupIssue == nil && !connectionState.isBusy && !connectionState.isLive && !callKitController.hasActiveCall
    }

    var canStop: Bool {
        callKitController.hasActiveCall || connectionState.isLive || connectionState.isBusy
    }

    func startConversation() async {
        await startConversation(handle: CallLaunchConstants.defaultHandle)
    }

    func startConversation(handle: String) async {
        guard configuration.startupIssue == nil else {
            appendStatus(configuration.startupIssue ?? "Missing configuration.")
            return
        }

        guard canStart else {
            appendStatus("Ignored start call request for \(handle) because a call is already active.")
            return
        }

        resetCallStartupState()
        usesSystemRouteControls = true

        do {
            try await callKitController.startCall(handle: handle)
            appendStatus("Requested CallKit call to \(handle).")
        } catch {
            if let error = error as NSError?,
               error.domain == CXErrorDomainRequestTransaction,
               error.code == CXErrorCodeRequestTransactionError.unentitled.rawValue {
                appendStatus("CallKit is unavailable for this runtime/signing context, falling back to the in-app voice session.")
                usesSystemRouteControls = false
                do {
                    // No CallKit → no didActivate callback, so configure + start directly.
                    try await configureConversationSession()
                    isCallKitAudioSessionActivated = true
                    tryStartAudioEngineIfReady()
                } catch {
                    appendStatus("Failed to start fallback voice session: \(error.localizedDescription)")
                }
                return
            }

            appendStatus("Failed to start CallKit call: \(error.localizedDescription)")
        }
    }

    func stopConversation() async {
        guard canStop else { return }
        if callKitController.hasActiveCall {
            await callKitController.endCall()
        } else {
            // Fallback path (CallKit unentitled) never set a CXCall, so
            // endCall() would no-op. Tear the in-app session down directly.
            await stopConversationSession()
        }
    }

    func togglePreferredOutputRoute() {
        let newRoute: AudioSessionController.OutputRoute = preferredOutputRoute == .phone ? .speaker : .phone
        do {
            try audioCoordinator.setPreferredOutputRoute(newRoute)
            preferredOutputRoute = newRoute
            currentOutputRoute = newRoute
            appendStatus("Audio route set to \(newRoute.title).")
        } catch {
            appendStatus("Failed to switch audio route: \(error.localizedDescription)")
        }
    }

    /// Phase 1: Connect WebSocket + configure audio session (but do NOT start the engine).
    /// Called from CXStartCallAction. Audio must not start until didActivate.
    private func configureConversationSession() async throws {
        appendStatus("Starting conversation using \(configuration.authModeDescription).")
        appendStatus("Connecting to \(configuration.realtimeWebSocketURL.absoluteString) with model \(configuration.model).")

        if isUITestCallKitMode {
            connectionState = .connecting
            appendStatus("UI test mode: simulating CallKit-connected voice session.")
            try? await Task.sleep(for: .milliseconds(150))
            connectionState = .connected
            appendStatus("Voice call started.")
            do {
                transcriptEntries = [
                    TranscriptEntry(
                        id: UUID().uuidString,
                        sourceItemIDs: ["ui-test-assistant-greeting"],
                        role: .assistant,
                        text: "Call connected. This is the simulator CallKit test path.",
                        isFinal: true,
                        updatedAt: .now
                    )
                ]
            }
            return
        }

        do {
            appendStatus("Configuring audio session.")
            audioCoordinator.setManualRouteOverrideEnabled(!usesSystemRouteControls)

            // Build the session up-front (constructor doesn't open the socket)
            // so the audio coordinator's input closure can capture it.
            connectionState = .connecting
            let token = try await resolveAuthToken()
            appendStatus("Auth resolved: \(configuration.authModeDescription).")
            let agent = BasicRealtimeAgent(
                name: "RVA",
                model: configuration.model,
                instructions: configuration.instructions,
                toolProvider: [toolRegistry],
                sessionConfiguration: makeRealtimeSessionConfiguration()
            )
            let model = OpenAIRealtimeWebSocketModel(
                openAI: OpenAI(apiKey: token),
                model: configuration.model
            )
            let session = RealtimeSession(agent: agent, model: model, modelIdentifier: configuration.model)
            self.session = session

            // Configure the audio session but do NOT start call audio here.
            // Call audio should not be started until the audio session is activated
            // by the system, after having its priority elevated (didActivate).
            // `commit: false, requestResponse: false` because server VAD handles
            // both segmentation and response-creation on speech_stopped.
            let audioDiagnostics = try await audioCoordinator.configure { [weak self] data in
                guard let session = await self?.session else { return }
                try? await session.sendAudio(data, commit: false, requestResponse: false)
            }
            isConversationSessionConfigured = true
            preferredOutputRoute = audioCoordinator.preferredOutputRoute
            currentOutputRoute = audioCoordinator.currentOutputRoute
            appendStatus("Audio session configured. Waiting for CallKit activation.")
            for line in audioDiagnostics.summaryLines {
                appendStatus(line)
            }
            tryStartAudioEngineIfReady()

            appendStatus("Opening realtime transport.")
            eventsTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await event in session.events {
                        self.handle(event)
                    }
                } catch {
                    self.handleSessionFailure(error.localizedDescription)
                }
            }
            try await session.connect()
            appendStatus("Realtime transport connected.")
        } catch {
            resetCallStartupState()
            eventsTask?.cancel()
            eventsTask = nil
            if let session {
                await session.disconnect()
            }
            self.session = nil
            audioCoordinator.stop()
            connectionState = .failed(error.localizedDescription)
            appendStatus("Failed to start: \(error.localizedDescription)")
            throw error
        }
    }

    private func resolveAuthToken() async throws -> String {
        if let endpoint = configuration.realtimeTokenEndpoint {
            return try await OpenAI.fetchEphemeralAPIKey(from: endpoint)
        }
        guard let apiKey = configuration.apiKey else {
            throw NSError(
                domain: "RealtimeVoiceAgent",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Missing realtime credentials."]
            )
        }
        return apiKey
    }

    private func makeRealtimeSessionConfiguration() -> RealtimeSessionConfiguration {
        let turnDetection: RealtimeSessionConfiguration.Audio.Input.TurnDetection? =
            configuration.useServerVAD
                ? .init(type: "semantic_vad", createResponse: true, interruptResponse: true)
                : nil
        return RealtimeSessionConfiguration(
            audio: .init(
                input: .init(
                    format: .init(type: "audio/pcm", rate: 24_000),
                    turnDetection: turnDetection,
                    transcription: .init(model: configuration.transcriptionModel),
                    noiseReduction: .init(type: "near_field")
                ),
                output: .init(
                    format: .init(type: "audio/pcm", rate: 24_000),
                    voice: configuration.voice
                )
            ),
            instructions: configuration.instructions,
            outputModalities: [.audio]
        )
    }

    /// Phase 2: Start the audio engine only once both configuration and CallKit activation have happened.
    private func handleCallKitAudioSessionActivated() {
        isCallKitAudioSessionActivated = true
        appendStatus("CallKit activated audio session.")
        tryStartAudioEngineIfReady()
    }

    private func tryStartAudioEngineIfReady() {
        guard !hasStartedAudioEngine else { return }

        guard isConversationSessionConfigured else {
            if isCallKitAudioSessionActivated {
                appendStatus("CallKit audio session is active, waiting for realtime/audio configuration before starting the engine.")
            }
            return
        }

        guard isCallKitAudioSessionActivated else {
            return
        }

        appendStatus("Starting audio engine.")
        do {
            try audioCoordinator.startEngine()
            hasStartedAudioEngine = true
            appendStatus("Audio engine started successfully. Voice call active.")
        } catch {
            appendStatus("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    private func stopConversationSession() async {
        appendStatus("Stopping conversation.")
        stopPlaybackSync()
        spokenTextTracker.reset()
        pendingHangup = false
        removeTrailingPlaceholders()
        persistConversationHistory()
        resetCallStartupState()
        usesSystemRouteControls = false

        if isUITestCallKitMode {
            connectionState = .disconnected
            backgroundTaskController.end()
            appendStatus("Voice call ended.")
            return
        }

        connectionState = .disconnecting
        audioCoordinator.stop()
        audioCoordinator.silenceFiller.stop()
        currentOutputRoute = .phone

        eventsTask?.cancel()
        eventsTask = nil
        if let session {
            await session.disconnect()
        }
        session = nil
        pendingToolNames.removeAll()
        currentAudioItemID = nil

        isAwaitingUserTranscript = false
        removeEmptyUserPlaceholderIfNeeded()
        pendingUserInsertionIndex = nil
        backgroundTaskController.end()
        callKitController.reportCallEndedIfNeeded(reason: .remoteEnded)
        connectionState = .disconnected
        appendStatus("Voice call ended.")
    }

    /// Cleanup path triggered by a server-side error or a thrown event-stream
    /// error — used to live in the `.state(.failed)` arm of the event handler.
    private func handleSessionFailure(_ message: String) {
        audioCoordinator.silenceFiller.stop()
        audioCoordinator.stop()
        isAwaitingUserTranscript = false
        removeEmptyUserPlaceholderIfNeeded()
        pendingUserInsertionIndex = nil
        backgroundTaskController.end()
        appendStatus(message)
        callKitController.reportCallEndedIfNeeded(reason: .failed)
        connectionState = .failed(message)
    }

    private func resetCallStartupState() {
        isConversationSessionConfigured = false
        isCallKitAudioSessionActivated = false
        hasStartedAudioEngine = false
    }

    var showsManualRouteToggle: Bool {
        (connectionState.isLive || connectionState.isBusy) && !usesSystemRouteControls
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            isSceneInBackground = true
            if connectionState.isLive {
                if hasActiveAssistantResponse {
                    backgroundTaskController.begin(name: "RealtimeVoiceAgentResponseCompletion")
                    appendStatus("App moved to background. Finishing the current response in the background if iOS allows it.")
                } else {
                    appendStatus("App moved to background. Audio may continue while iOS keeps the audio session alive.")
                }
            }
        case .active:
            isSceneInBackground = false
            backgroundTaskController.end()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func handle(_ event: RealtimeSessionEvent) {
        switch event {
        case .sessionCreated, .sessionUpdated:
            if connectionState != .connected {
                connectionState = .connected
                appendStatus("Realtime session connected.")
                if configuration.realtimeTokenEndpoint == nil, configuration.apiKey != nil {
                    appendStatus(
                        "Using a bundled API key. Replace it with a backend-issued ephemeral token before shipping."
                    )
                }
            }

        case .responseCreated:
            setResponseActive(true)

        case .responseCompleted:
            setResponseActive(false)
            audioCoordinator.flushPlayback()

        case let .audioDelta(payload):
            currentAudioItemID = payload.itemId
            currentAudioContentIndex = payload.contentIndex
            guard let data = payload.delta else { return }
            audioCoordinator.silenceFiller.stop()
            audioCoordinator.enqueueOutputPCM16(data, itemID: payload.itemId, contentIndex: payload.contentIndex)
            startPlaybackSync()

        case let .inputAudioTranscriptDelta(payload):
            applyTranscript(itemID: payload.itemId, role: .user, text: payload.delta, isFinal: false, replace: false)

        case let .inputAudioTranscriptDone(payload):
            applyTranscript(itemID: payload.itemId, role: .user, text: payload.transcript, isFinal: true, replace: true)

        case let .outputAudioTranscriptDelta(payload):
            applyTranscript(itemID: payload.itemId, role: .assistant, text: payload.delta, isFinal: false, replace: false)

        case let .outputAudioTranscriptDone(payload):
            applyTranscript(itemID: payload.itemId, role: .assistant, text: payload.transcript, isFinal: true, replace: true)

        case let .textDelta(payload):
            applyTranscript(itemID: payload.itemId, role: .assistant, text: payload.delta, isFinal: false, replace: false)

        case let .textDone(payload):
            applyTranscript(itemID: payload.itemId, role: .assistant, text: payload.text, isFinal: true, replace: true)

        case let .toolCalled(call):
            pendingToolNames[call.callId] = call.name
            audioCoordinator.silenceFiller.start(immediate: true)
            applyTranscript(
                itemID: "tool-\(call.callId)",
                role: .tool,
                text: "Running \(call.name)…",
                isFinal: false,
                replace: true
            )
            appendStatus("Tool call requested: \(call.name) args=\(call.arguments)")

        case let .toolOutput(output):
            let name = pendingToolNames.removeValue(forKey: output.callId) ?? "tool"
            let displayText = name == output.output ? output.output : "\(name): \(output.output)"
            applyTranscript(
                itemID: "tool-\(output.callId)",
                role: .tool,
                text: displayText,
                isFinal: true,
                replace: true
            )
            appendStatus("Tool result ready: \(name) -> \(output.output)")
            if name == "hangup" {
                appendStatus("Hangup requested by agent. Waiting for playback to finish.")
                pendingHangup = true
            }

        case .inputSpeechStarted:
            isAwaitingUserTranscript = shouldShowUserSpeechPlaceholder
            if isAwaitingUserTranscript {
                ensureUserSpeechPlaceholder()
            }
            handleBargeIn()

        case .inputSpeechStopped:
            isAwaitingUserTranscript = false

        case let .error(detail):
            let code = detail.code.map { " [\($0)]" } ?? ""
            appendStatus("Realtime error\(code): \(detail.message)")
            if detail.code == "response_cancel_not_active" {
                appendStatus("Ignoring benign cancel error (no assistant response in flight).")
            } else {
                handleSessionFailure(detail.message)
            }

        case .raw, .audioDone, .historyChange:
            break
        }
    }

    private func setResponseActive(_ isActive: Bool) {
        hasActiveAssistantResponse = isActive
        guard isSceneInBackground else { return }
        if isActive {
            backgroundTaskController.begin(name: "RealtimeVoiceAgentResponseCompletion")
        } else {
            backgroundTaskController.end()
        }
    }

    /// User started speaking while the assistant was talking — stop local
    /// playback, freeze the transcript at what was actually spoken, ask the
    /// server to truncate the in-flight item, and cancel the active response.
    private func handleBargeIn() {
        audioCoordinator.silenceFiller.stop()
        let progress = audioCoordinator.playbackProgress
        let itemID = currentAudioItemID ?? ""
        let contentIndex = currentAudioContentIndex
        audioCoordinator.clearPlayback()
        stopPlaybackSync()
        if pendingHangup {
            pendingHangup = false
            appendStatus("User barged in — cancelling pending hangup.")
        }
        truncatedItemIDs.insert(itemID)

        let trackedEntryID = spokenTextTracker.entryID
        let spokenText = spokenTextTracker.interrupt()
        if let entryID = trackedEntryID,
           let index = transcriptEntries.firstIndex(where: { $0.id == entryID }) {
            if let spokenText {
                transcriptEntries[index].text = spokenText
            }
            transcriptEntries[index].isFinal = true
            transcriptEntries[index].updatedAt = Date()
            appendStatus("Interrupted: kept \(spokenText?.count ?? 0) chars of buffer")
        }

        if let progress, !itemID.isEmpty, let session {
            let audioEndMs = Int(progress.playedMs)
            Task {
                try? await session.interruptPlayback(
                    itemID: itemID,
                    contentIndex: contentIndex,
                    audioEndMilliseconds: audioEndMs
                )
            }
        }
        if let session {
            Task { try? await session.cancelResponse() }
        }
    }

    private var shouldShowUserSpeechPlaceholder: Bool {
        guard let lastUserEntry = transcriptEntries.last(where: { $0.role == .user }) else {
            return true
        }
        return lastUserEntry.isFinal
    }

    private func applyTranscript(
        itemID: String,
        role: TranscriptRole,
        text: String,
        fullOutput: String? = nil,
        isFinal: Bool,
        replace: Bool
    ) {
        guard !text.isEmpty else { return }
        let now = Date()

        // Drop late deltas for items that were already truncated by interruption
        if truncatedItemIDs.contains(itemID) { return }

        if role == .user {
            isAwaitingUserTranscript = false
        } else {
            removeEmptyUserPlaceholderIfNeeded()
        }

        // --- Assistant audio entries: route through SpokenTextTracker ---

        // If the tracker is already following this item, always buffer there
        // (even after response.done — audio may still be playing)
        if spokenTextTracker.itemID == itemID {
            if replace {
                spokenTextTracker.replaceWithFinal(text)
            } else {
                spokenTextTracker.appendDelta(text)
            }
            return
        }

        // New assistant entry while audio is active — start tracking
        if role == .assistant && (hasActiveAssistantResponse || audioCoordinator.currentItemID != nil) {
            // Existing entry for a different assistant item (no tracker) — update directly
            if let existingIndex = transcriptEntries.firstIndex(where: { $0.sourceItemIDs.contains(itemID) }) {
                transcriptEntries[existingIndex].text = replace
                    ? replaceLastParagraph(in: transcriptEntries[existingIndex].text, with: text)
                    : transcriptEntries[existingIndex].text + text
                transcriptEntries[existingIndex].isFinal = isFinal
                transcriptEntries[existingIndex].updatedAt = now
                return
            }

            // New assistant entry — create it with empty text, start tracking
            let newID = UUID().uuidString
            transcriptEntries.append(
                TranscriptEntry(
                    id: newID,
                    sourceItemIDs: [itemID],
                    role: .assistant,
                    text: "",
                    isFinal: false,
                    updatedAt: now
                )
            )
            spokenTextTracker.begin(entryID: newID, itemID: itemID)
            spokenTextTracker.appendDelta(text)
            return
        }

        // --- Non-tracked assistant deltas (e.g. text-only, no audio) ---
        // --- User / Tool / System entries: original logic ---

        if let existingIndex = transcriptEntries.firstIndex(where: { $0.sourceItemIDs.contains(itemID) }) {
            transcriptEntries[existingIndex].text = replace
                ? replaceLastParagraph(in: transcriptEntries[existingIndex].text, with: text)
                : transcriptEntries[existingIndex].text + text
            transcriptEntries[existingIndex].isFinal = isFinal
            transcriptEntries[existingIndex].updatedAt = now
            if let fullOutput {
                transcriptEntries[existingIndex].fullOutput = fullOutput
            }
            return
        }

        if role == .user,
           let provisionalIndex = transcriptEntries.lastIndex(where: { $0.role == .user && !$0.isFinal }) {
            if transcriptEntries[provisionalIndex].id == activeUserPlaceholderID {
                if provisionalIndex > 0,
                   transcriptEntries[provisionalIndex - 1].role == .user,
                   transcriptEntries[provisionalIndex - 1].isFinal {
                    transcriptEntries[provisionalIndex - 1].sourceItemIDs.append(itemID)
                    transcriptEntries[provisionalIndex - 1].text += "\n\n" + text
                    transcriptEntries[provisionalIndex - 1].isFinal = isFinal
                    transcriptEntries[provisionalIndex - 1].updatedAt = now
                    transcriptEntries.remove(at: provisionalIndex)
                } else {
                    transcriptEntries[provisionalIndex].sourceItemIDs = [itemID]
                    transcriptEntries[provisionalIndex].text = text
                    transcriptEntries[provisionalIndex].isFinal = isFinal
                    transcriptEntries[provisionalIndex].updatedAt = now
                }
                activeUserPlaceholderID = nil
                return
            }

            transcriptEntries[provisionalIndex].text = replace || isFinal
                ? text
                : transcriptEntries[provisionalIndex].text + text
            transcriptEntries[provisionalIndex].isFinal = isFinal
            transcriptEntries[provisionalIndex].updatedAt = now
            return
        }

        if role == .user,
           let pendingUserInsertionIndex {
            let entry = TranscriptEntry(
                id: UUID().uuidString,
                sourceItemIDs: [itemID],
                role: .user,
                text: text,
                isFinal: isFinal,
                updatedAt: now
            )
            transcriptEntries.insert(entry, at: min(pendingUserInsertionIndex, transcriptEntries.count))
            self.pendingUserInsertionIndex = nil
            return
        }

        if role == .user,
           let lastIndex = transcriptEntries.indices.last,
           transcriptEntries[lastIndex].role == .user,
           transcriptEntries[lastIndex].isFinal {
            transcriptEntries[lastIndex].sourceItemIDs.append(itemID)
            transcriptEntries[lastIndex].text += "\n\n" + text
            transcriptEntries[lastIndex].isFinal = isFinal
            transcriptEntries[lastIndex].updatedAt = now
            return
        }

        transcriptEntries.append(
            TranscriptEntry(
                id: UUID().uuidString,
                sourceItemIDs: [itemID],
                role: role,
                text: text,
                fullOutput: fullOutput,
                isFinal: isFinal,
                updatedAt: now
            )
        )
    }

    private func ensureUserSpeechPlaceholder() {
        guard shouldShowUserSpeechPlaceholder else { return }
        guard transcriptEntries.last?.role != .user || transcriptEntries.last?.isFinal == true else { return }

        let placeholderID = "user-speech-placeholder-\(UUID().uuidString)"
        activeUserPlaceholderID = placeholderID
        pendingUserInsertionIndex = nil
        do {
            transcriptEntries.append(
                TranscriptEntry(
                    id: placeholderID,
                    sourceItemIDs: [],
                    role: .user,
                    text: "",
                    isFinal: false,
                    updatedAt: Date()
                )
            )
        }
    }

    private func removeEmptyUserPlaceholderIfNeeded() {
        guard let activeUserPlaceholderID,
              let placeholderIndex = transcriptEntries.firstIndex(where: { $0.id == activeUserPlaceholderID }) else { return }
        let entry = transcriptEntries[placeholderIndex]
        guard entry.text.isEmpty, !entry.isFinal else { return }
        transcriptEntries.remove(at: placeholderIndex)
        self.activeUserPlaceholderID = nil
        pendingUserInsertionIndex = placeholderIndex
    }

    private func replaceLastParagraph(in existingText: String, with replacement: String) -> String {
        guard let range = existingText.range(of: "\n\n", options: .backwards) else {
            return replacement
        }
        return String(existingText[..<range.upperBound]) + replacement
    }

    // MARK: - Playback Sync

    private func startPlaybackSync() {
        guard playbackSyncTask == nil else { return }
        playbackSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { break }
                self.tickSpokenText()
            }
        }
    }

    private func stopPlaybackSync() {
        playbackSyncTask?.cancel()
        playbackSyncTask = nil
    }

    private func tickSpokenText() {
        guard spokenTextTracker.isActive else {
            if !hasActiveAssistantResponse {
                Self.logger.info("[tick] Tracker inactive, response done → stopping sync")
                stopPlaybackSync()
            }
            return
        }

        guard let progress = audioCoordinator.playbackProgress,
              progress.totalReceivedMs > 0 else {
            if !hasActiveAssistantResponse {
                Self.logger.info("[tick] No playback progress, response done → finalizing")
                finalizeSpokenText()
                stopPlaybackSync()
            }
            return
        }

        if let result = spokenTextTracker.tick(playedMs: progress.playedMs, totalReceivedMs: progress.totalReceivedMs) {
            if let entryID = spokenTextTracker.entryID,
               let index = transcriptEntries.firstIndex(where: { $0.id == entryID }) {
                Self.logger.info("[spoken] Setting text (\(result.text.count) chars): \"\(result.text.suffix(60), privacy: .public)\"")
                transcriptEntries[index].text = result.text
                transcriptEntries[index].updatedAt = Date()
            } else {
                Self.logger.warning("[spoken] Tick returned text but entry \(self.spokenTextTracker.entryID ?? "nil", privacy: .public) not found")
            }
        }

        // All buffers consumed by the audio engine — reveal the full text
        if progress.isComplete && !hasActiveAssistantResponse {
            Self.logger.info("[tick] All audio consumed (played=\(Int(progress.playedMs))ms, total=\(Int(progress.totalReceivedMs))ms) → finalizing")
            finalizeSpokenText()
            stopPlaybackSync()
        }
    }

    private func finalizeSpokenText() {
        guard let entryID = spokenTextTracker.entryID,
              let fullText = spokenTextTracker.complete(),
              let index = transcriptEntries.firstIndex(where: { $0.id == entryID }) else {
            spokenTextTracker.reset()
            checkPendingHangup()
            return
        }
        transcriptEntries[index].text = fullText
        transcriptEntries[index].isFinal = true
        transcriptEntries[index].updatedAt = Date()
        checkPendingHangup()
    }

    private func checkPendingHangup() {
        guard pendingHangup else { return }
        pendingHangup = false
        appendStatus("Executing pending hangup.")
        removeTrailingPlaceholders()
        Task { await stopConversation() }
    }

    private func persistConversationHistory() {
        guard let session else { return }
        Task {
            let items = await session.historySnapshot()
            guard !items.isEmpty else { return }
            do {
                try RealtimeHistory.save(items, to: Self.historyFileURL)
                await MainActor.run {
                    self.appendStatus("Persisted \(items.count) conversation items to history.")
                }
            } catch {
                await MainActor.run {
                    self.appendStatus("Failed to persist history: \(error.localizedDescription)")
                }
            }
        }
    }

    private static let historyFileURL: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("conversation_history.json")

    private func removeTrailingPlaceholders() {
        // Remove empty/unfinal bubbles at the end (typing dots for assistant or user)
        while let last = transcriptEntries.last,
              last.text.isEmpty && !last.isFinal {
            transcriptEntries.removeLast()
        }
    }

    private func appendStatus(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        let line = "[\(timestamp)] \(message)"
        statusMessages.append(line)
        Self.logger.info("\(line, privacy: .public)")
        if statusMessages.count > 40 {
            statusMessages.removeFirst(statusMessages.count - 40)
        }
    }
}
