import CallKit
import OSLog
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
    private let service: OpenAIRealtimeService
    private let toolRegistry: LocalToolRegistry
    private let callKitController: CallKitController
    private let isUITestCallKitMode: Bool

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
        self.service = OpenAIRealtimeService(configuration: configuration, toolRegistry: toolRegistry)

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

        bindEvents()

        // transcriptEntries = OpenAIRealtimeService.loadTranscriptEntries()

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

            // Configure the audio session but do NOT start call audio here.
            // Call audio should not be started until the audio session is activated
            // by the system, after having its priority elevated (didActivate).
            let audioDiagnostics = try await audioCoordinator.configure { [service] data in
                await service.appendInputAudioChunk(data)
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
            try await service.connect()
            appendStatus("Realtime transport connected.")
        } catch {
            resetCallStartupState()
            await service.disconnect()
            audioCoordinator.stop()
            connectionState = .failed(error.localizedDescription)
            appendStatus("Failed to start: \(error.localizedDescription)")
            throw error
        }
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

        audioCoordinator.stop()
        currentOutputRoute = .phone
        await service.disconnect()
        backgroundTaskController.end()
        appendStatus("Voice call ended.")
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

    private func bindEvents() {
        eventsTask = Task { [weak self] in
            guard let self else { return }

            for await event in service.events {
                self.handle(event)
            }
        }
    }

    private func handle(_ event: RealtimeServiceEvent) {
        switch event {
        case .state(let state):
            connectionState = state

            switch state {
            case .connected:
                appendStatus("Realtime session connected.")
            case .disconnected:
                audioCoordinator.silenceFiller.stop()
                isAwaitingUserTranscript = false
                removeEmptyUserPlaceholderIfNeeded()
                pendingUserInsertionIndex = nil
                backgroundTaskController.end()
                callKitController.reportCallEndedIfNeeded(reason: .remoteEnded)
            case .failed(let message):
                audioCoordinator.silenceFiller.stop()
                isAwaitingUserTranscript = false
                removeEmptyUserPlaceholderIfNeeded()
                pendingUserInsertionIndex = nil
                audioCoordinator.stop()
                backgroundTaskController.end()
                appendStatus(message)
                callKitController.reportCallEndedIfNeeded(reason: .failed)
            default:
                break
            }

        case .responseActive(let isActive):
            hasActiveAssistantResponse = isActive
            if isSceneInBackground {
                if isActive {
                    backgroundTaskController.begin(name: "RealtimeVoiceAgentResponseCompletion")
                } else {
                    backgroundTaskController.end()
                }
            }

        case .transcript(let delta):
            applyTranscript(delta)

        case .userSpeechDetected(let isSpeaking):
            isAwaitingUserTranscript = isSpeaking && shouldShowUserSpeechPlaceholder
            if isSpeaking {
                ensureUserSpeechPlaceholder()
            }

        case .toolCallBegan:
            audioCoordinator.silenceFiller.start(immediate: true)

        case .audioOutput(let chunk):
            audioCoordinator.silenceFiller.stop()
            audioCoordinator.enqueueOutputPCM16(chunk.data, itemID: chunk.itemID, contentIndex: chunk.contentIndex)
            startPlaybackSync()

        case .flushPlayback:
            audioCoordinator.flushPlayback()
            // Don't finalize here — audio is still playing from the buffer.
            // The sync timer will detect when playback catches up and finalize.

        case .interruptPlayback(let interrupt):
            audioCoordinator.silenceFiller.stop()
            let progress = audioCoordinator.playbackProgress
            audioCoordinator.clearPlayback()
            stopPlaybackSync()
            if pendingHangup {
                pendingHangup = false
                appendStatus("User barged in — cancelling pending hangup.")
            }
            truncatedItemIDs.insert(interrupt.itemID)

            // Freeze the transcript at exactly what was spoken
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

            if let progress, !interrupt.itemID.isEmpty {
                let audioEndMs = Int(progress.playedMs)
                Task {
                    await service.truncateItem(
                        id: interrupt.itemID,
                        contentIndex: interrupt.contentIndex,
                        audioEndMs: audioEndMs
                    )
                }
            }

        case .hangupRequested:
            appendStatus("Hangup requested by agent. Waiting for playback to finish.")
            pendingHangup = true

        case .log(let message):
            appendStatus(message)

        @unknown default:
            break
        }
    }

    private var shouldShowUserSpeechPlaceholder: Bool {
        guard let lastUserEntry = transcriptEntries.last(where: { $0.role == .user }) else {
            return true
        }
        return lastUserEntry.isFinal
    }

    private func applyTranscript(_ delta: TranscriptDelta) {
        let now = Date()

        // Drop late deltas for items that were already truncated by interruption
        if truncatedItemIDs.contains(delta.itemID) { return }

        if delta.role == .user {
            isAwaitingUserTranscript = false
        } else {
            removeEmptyUserPlaceholderIfNeeded()
        }

        // --- Assistant audio entries: route through SpokenTextTracker ---

        // If the tracker is already following this item, always buffer there
        // (even after response.done — audio may still be playing)
        if spokenTextTracker.itemID == delta.itemID {
            if delta.replace {
                spokenTextTracker.replaceWithFinal(delta.text)
            } else {
                spokenTextTracker.appendDelta(delta.text)
            }
            return
        }

        // New assistant entry while audio is active — start tracking
        if delta.role == .assistant && (hasActiveAssistantResponse || audioCoordinator.currentItemID != nil) {
            // Existing entry for a different assistant item (no tracker) — update directly
            if let existingIndex = transcriptEntries.firstIndex(where: { $0.sourceItemIDs.contains(delta.itemID) }) {
                do {
                    transcriptEntries[existingIndex].text = delta.replace
                        ? replaceLastParagraph(in: transcriptEntries[existingIndex].text, with: delta.text)
                        : transcriptEntries[existingIndex].text + delta.text
                    transcriptEntries[existingIndex].isFinal = delta.isFinal
                    transcriptEntries[existingIndex].updatedAt = now
                }
                return
            }

            // New assistant entry — create it with empty text, start tracking
            let newID = UUID().uuidString
            do {
                transcriptEntries.append(
                    TranscriptEntry(
                        id: newID,
                        sourceItemIDs: [delta.itemID],
                        role: .assistant,
                        text: "",
                        isFinal: false,
                        updatedAt: now
                    )
                )
            }
            spokenTextTracker.begin(entryID: newID, itemID: delta.itemID)
            spokenTextTracker.appendDelta(delta.text)
            return
        }

        // --- Non-tracked assistant deltas (e.g. text-only, no audio) ---
        // --- User / Tool / System entries: original logic ---

        if let existingIndex = transcriptEntries.firstIndex(where: { $0.sourceItemIDs.contains(delta.itemID) }) {
            // If the tracker WAS tracking this item but response ended, apply the final text
            do {
                transcriptEntries[existingIndex].text = delta.replace
                    ? replaceLastParagraph(in: transcriptEntries[existingIndex].text, with: delta.text)
                    : transcriptEntries[existingIndex].text + delta.text
                transcriptEntries[existingIndex].isFinal = delta.isFinal
                transcriptEntries[existingIndex].updatedAt = now
                if let fullOutput = delta.fullOutput {
                    transcriptEntries[existingIndex].fullOutput = fullOutput
                }
            }
            return
        }

        if delta.role == .user,
           let provisionalIndex = transcriptEntries.lastIndex(where: { $0.role == .user && !$0.isFinal }) {
            if transcriptEntries[provisionalIndex].id == activeUserPlaceholderID {
                do {
                    if provisionalIndex > 0,
                       transcriptEntries[provisionalIndex - 1].role == .user,
                       transcriptEntries[provisionalIndex - 1].isFinal {
                        transcriptEntries[provisionalIndex - 1].sourceItemIDs.append(delta.itemID)
                        transcriptEntries[provisionalIndex - 1].text += "\n\n" + delta.text
                        transcriptEntries[provisionalIndex - 1].isFinal = delta.isFinal
                        transcriptEntries[provisionalIndex - 1].updatedAt = now
                        transcriptEntries.remove(at: provisionalIndex)
                    } else {
                        transcriptEntries[provisionalIndex].sourceItemIDs = [delta.itemID]
                        transcriptEntries[provisionalIndex].text = delta.text
                        transcriptEntries[provisionalIndex].isFinal = delta.isFinal
                        transcriptEntries[provisionalIndex].updatedAt = now
                    }
                }
                activeUserPlaceholderID = nil
                return
            }

            do {
                transcriptEntries[provisionalIndex].text = delta.replace || delta.isFinal
                    ? delta.text
                    : transcriptEntries[provisionalIndex].text + delta.text
                transcriptEntries[provisionalIndex].isFinal = delta.isFinal
                transcriptEntries[provisionalIndex].updatedAt = now
            }
            return
        }

        if delta.role == .user,
           let pendingUserInsertionIndex {
            let entry = TranscriptEntry(
                id: UUID().uuidString,
                sourceItemIDs: [delta.itemID],
                role: .user,
                text: delta.text,
                isFinal: delta.isFinal,
                updatedAt: now
            )
            do {
                transcriptEntries.insert(entry, at: min(pendingUserInsertionIndex, transcriptEntries.count))
            }
            self.pendingUserInsertionIndex = nil
            return
        }

        if delta.role == .user,
           let lastIndex = transcriptEntries.indices.last,
           transcriptEntries[lastIndex].role == .user,
           transcriptEntries[lastIndex].isFinal {
            do {
                transcriptEntries[lastIndex].sourceItemIDs.append(delta.itemID)
                transcriptEntries[lastIndex].text += "\n\n" + delta.text
                transcriptEntries[lastIndex].isFinal = delta.isFinal
                transcriptEntries[lastIndex].updatedAt = now
            }
            return
        }

        do {
            transcriptEntries.append(
                TranscriptEntry(
                    id: UUID().uuidString,
                    sourceItemIDs: [delta.itemID],
                    role: delta.role,
                    text: delta.text,
                    fullOutput: delta.fullOutput,
                    isFinal: delta.isFinal,
                    updatedAt: now
                )
            )
        }
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
        let turns = transcriptEntries.compactMap { entry -> (role: String, text: String)? in
            guard entry.isFinal, !entry.text.isEmpty else { return nil }
            switch entry.role {
            case .assistant: return ("assistant", entry.text)
            case .user:      return ("user", entry.text)
            case .tool:      return ("tool", entry.text)
            case .system:    return nil
            }
        }
        guard !turns.isEmpty else { return }
        OpenAIRealtimeService.saveHistory(turns: turns)
        appendStatus("Persisted \(turns.count) conversation turns to history.")
    }

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
