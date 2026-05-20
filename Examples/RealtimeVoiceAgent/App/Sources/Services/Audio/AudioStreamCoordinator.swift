@preconcurrency import AVFAudio
import Foundation
import OSLog

@MainActor
final class AudioStreamCoordinator {
    enum AudioStartError: LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Audio engine cannot start before the input sink is configured."
            }
        }
    }

    private static let logger = Logger(subsystem: "RealtimeVoiceAgent", category: "AudioPlayback")
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    let sessionController: AudioSessionController
    private var engineConfigurationObserver: NSObjectProtocol?

    let silenceFiller: SilenceFiller

    private var captureConverter: AVAudioConverter?
    private var inputSink: (@Sendable (Data) async -> Void)?
    private var pendingPlaybackData = Data()
    private var queuedPlaybackFrames: Int = 0
    private var isPlaybackPrimed = false
    private var isHandlingEngineConfigurationChange = false

    // MARK: - Playback Tracking

    private(set) var currentItemID: String?
    private(set) var currentContentIndex: Int = 0
    private(set) var totalReceivedFrames: Int = 0
    /// Frames whose buffers have been played back by the audio engine (via callbacks).
    private(set) var consumedFrames: Int = 0
    /// Total frames ever sent to scheduleBuffer for the current item.
    private(set) var totalScheduledFrames: Int = 0
    private(set) var lastInterruptedPlayedMs: Double?
    /// Generation counter — incremented on every item change, clear, or stop.
    /// Callbacks from older generations are silently dropped.
    private var itemGeneration: Int = 0

    struct PlaybackProgress {
        let itemID: String
        let contentIndex: Int
        /// Frames consumed by the audio engine for this item.
        let playedMs: Double
        let totalReceivedMs: Double
        /// True when all received frames have been scheduled AND consumed.
        let isComplete: Bool
    }

    var playbackProgress: PlaybackProgress? {
        guard let itemID = currentItemID else { return nil }
        return PlaybackProgress(
            itemID: itemID,
            contentIndex: currentContentIndex,
            playedMs: Double(consumedFrames) / 24.0,
            totalReceivedMs: Double(totalReceivedFrames) / 24.0,
            isComplete: totalScheduledFrames > 0 && consumedFrames >= totalScheduledFrames
        )
    }

    func setCurrentItem(id: String, contentIndex: Int) {
        if currentItemID != id || currentContentIndex != contentIndex {
            itemGeneration += 1
            currentItemID = id
            currentContentIndex = contentIndex
            totalReceivedFrames = 0
            consumedFrames = 0
            totalScheduledFrames = 0
            Self.logger.info("New item: \(id, privacy: .public) gen=\(self.itemGeneration)")
        }
    }

    var onRouteChanged: ((@MainActor () -> Void))?
    var onRouteChangeStatus: ((@MainActor (String) -> Void))?

    private let pcm16Mono24k = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    private var bytesPerFrame: Int {
        MemoryLayout<Int16>.size * Int(pcm16Mono24k.channelCount)
    }

    private var prerollFrames: Int {
        Int(pcm16Mono24k.sampleRate * 0.20)
    }

    private var minimumScheduleFrames: Int {
        Int(pcm16Mono24k.sampleRate * 0.10)
    }

    private var targetQueuedFrames: Int {
        Int(pcm16Mono24k.sampleRate * 0.35)
    }

    init(sessionController: AudioSessionController = AudioSessionController()) {
        self.sessionController = sessionController
        self.silenceFiller = SilenceFiller(format: pcm16Mono24k)
        engine.attach(playerNode)
        engine.attach(silenceFiller.node)

        self.sessionController.onRouteChange = { [weak self] reason in
            self?.handleRouteChange(reason: reason)
        }
        startObservingEngineConfigurationChanges()
    }

    // MARK: - Two-Phase Audio Lifecycle (matches Apple's CallKit sample)

    /// Phase 1: Configure the audio session but do NOT start the engine.
    /// Called from CXStartCallAction / CXAnswerCallAction.
    /// Audio should not be started until the system activates the audio session (didActivate).
    func configure(onInputPCM16: @escaping @Sendable (Data) async -> Void) async throws -> AudioSessionDiagnostics {
        inputSink = onInputPCM16
        let diagnostics = try await sessionController.configureForRealtimeConversation()
        return diagnostics
    }

    /// Phase 2: Start the audio engine and begin capturing/playing.
    /// Called from CXProvider's didActivate(audioSession:) callback,
    /// after the system has elevated the audio session's priority.
    func startEngine() throws {
        guard inputSink != nil else {
            Self.logger.error("startEngine called before configure, no input sink set.")
            throw AudioStartError.notConfigured
        }
        try configureAudioGraph(resetPlaybackState: true)
        Self.logger.info("Audio engine started via didActivate.")
    }

    /// Stop everything. Called from CXEndCallAction.
    func stop() {
        silenceFiller.stop()
        itemGeneration += 1
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        playerNode.reset()
        engine.stop()
        engine.reset()
        inputSink = nil
        pendingPlaybackData.removeAll(keepingCapacity: false)
        queuedPlaybackFrames = 0
        consumedFrames = 0
        totalScheduledFrames = 0
        totalReceivedFrames = 0
        currentItemID = nil
        currentContentIndex = 0
        lastInterruptedPlayedMs = nil
        isPlaybackPrimed = false
        sessionController.deactivate()
    }

    // MARK: - Playback Control

    func clearPlayback() {
        let playedMs = Double(consumedFrames) / 24.0
        lastInterruptedPlayedMs = playedMs
        Self.logger.info("Clearing playback. Consumed \(self.consumedFrames) frames (\(playedMs, privacy: .public) ms), scheduled \(self.totalScheduledFrames), received \(self.totalReceivedFrames) for item \(self.currentItemID ?? "nil", privacy: .public) gen=\(self.itemGeneration)")
        itemGeneration += 1
        playerNode.stop()
        playerNode.reset()
        pendingPlaybackData.removeAll(keepingCapacity: true)
        queuedPlaybackFrames = 0
        consumedFrames = 0
        totalScheduledFrames = 0
        totalReceivedFrames = 0
        isPlaybackPrimed = false
        if engine.isRunning {
            playerNode.play()
        }
    }

    func softClearPlayback() {
        pendingPlaybackData.removeAll(keepingCapacity: true)
        queuedPlaybackFrames = 0
        isPlaybackPrimed = false
        Self.logger.info("Cleared pending playback for CallKit without stopping or resetting the player node.")
    }

    var preferredOutputRoute: AudioSessionController.OutputRoute {
        sessionController.preferredOutputRoute
    }

    var currentOutputRoute: AudioSessionController.OutputRoute {
        sessionController.currentOutputRoute
    }

    func setManualRouteOverrideEnabled(_ enabled: Bool) {
        sessionController.setManualRouteOverrideEnabled(enabled)
    }

    func setPreferredOutputRoute(_ route: AudioSessionController.OutputRoute) throws {
        try sessionController.setPreferredOutputRoute(route)
    }

    func flushPlayback() {
        drainPendingPlayback(force: true)
    }

    func enqueueOutputPCM16(_ data: Data, itemID: String, contentIndex: Int) {
        setCurrentItem(id: itemID, contentIndex: contentIndex)

        guard engine.isRunning else {
            Self.logger.error("Dropping output audio chunk because engine is not running.")
            return
        }

        let alignedByteCount = data.count - (data.count % bytesPerFrame)
        guard alignedByteCount > 0 else {
            Self.logger.error("Received output audio chunk without a full PCM16 frame.")
            return
        }

        if alignedByteCount < data.count {
            Self.logger.info("Dropping \(data.count - alignedByteCount, privacy: .public) trailing output bytes to preserve PCM16 frame alignment.")
        }

        totalReceivedFrames += alignedByteCount / bytesPerFrame
        pendingPlaybackData.append(data.prefix(alignedByteCount))
        drainPendingPlayback(force: false)
    }

    // MARK: - Route Change Handling

    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
        onRouteChanged?()

        guard inputSink != nil else {
            Self.logger.info("Route change observed before audio input was configured.")
            return
        }

        // Match the Speakerbox sample more closely: route changes are observed and
        // reflected in app state, but do not trigger engine teardown/rebuild.
        // Rebuilding here is what makes repeated speaker toggles flaky under CallKit.
        let message = engine.isRunning
            ? "Adopted external audio route change without rebuilding the graph."
            : "Observed audio route change while the engine reported inactive; leaving the graph untouched."
        Self.logger.info("\(message, privacy: .public)")
        onRouteChangeStatus?(message)
    }

    private func handleEngineConfigurationChange() {
        guard inputSink != nil else {
            Self.logger.info("Ignoring engine configuration change because audio input is not configured.")
            return
        }

        guard !isHandlingEngineConfigurationChange else {
            Self.logger.info("Skipping re-entrant engine configuration change handling.")
            return
        }

        isHandlingEngineConfigurationChange = true
        defer { isHandlingEngineConfigurationChange = false }

        let message = "Audio engine configuration changed."
        Self.logger.info("\(message, privacy: .public)")
        onRouteChangeStatus?(message)

        if engine.isRunning {
            // Prefer a lightweight player refresh first. Rebuilding the full engine graph
            // after a speaker/receiver route flip tends to make the Dynamic Island route
            // button lose its selected state even when audio survives.
            playerNode.stop()
            playerNode.reset()
            queuedPlaybackFrames = 0
            isPlaybackPrimed = false
            playerNode.play()

            if !pendingPlaybackData.isEmpty {
                drainPendingPlayback(force: true)
            }

            onRouteChangeStatus?("Refreshed playback after configuration change.")
            return
        }

        do {
            try configureAudioGraph(resetPlaybackState: false)
            if !pendingPlaybackData.isEmpty {
                drainPendingPlayback(force: true)
            }
            onRouteChangeStatus?("Recovered audio engine after configuration change.")
        } catch {
            Self.logger.error("Failed to rebuild audio graph after configuration change: \(error.localizedDescription, privacy: .public)")
            onRouteChangeStatus?("Failed to recover audio after configuration change: \(error.localizedDescription)")
        }
    }

    // MARK: - Playback Drain

    private func drainPendingPlayback(force: Bool) {
        guard engine.isRunning else { return }

        let pendingFrames = pendingPlaybackData.count / bytesPerFrame
        if !isPlaybackPrimed {
            if !force, pendingFrames < prerollFrames {
                Self.logger.info("Buffering playback preroll: pendingFrames=\(pendingFrames, privacy: .public) target=\(self.prerollFrames, privacy: .public)")
                return
            }
            isPlaybackPrimed = true
        }

        while pendingPlaybackData.count >= minimumScheduleFrames * bytesPerFrame || (force && !pendingPlaybackData.isEmpty) {
            if !force, queuedPlaybackFrames >= targetQueuedFrames {
                break
            }

            let framesToSchedule = min(minimumScheduleFrames, pendingPlaybackData.count / bytesPerFrame)
            guard framesToSchedule > 0 else { break }

            let byteCount = framesToSchedule * bytesPerFrame
            let chunk = pendingPlaybackData.prefix(byteCount)
            pendingPlaybackData.removeFirst(byteCount)
            schedulePlaybackChunk(Data(chunk), frameCount: framesToSchedule)
        }
    }

    private func schedulePlaybackChunk(_ data: Data, frameCount: Int) {
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: pcm16Mono24k, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = sourceBuffer.int16ChannelData else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            channelData[0].update(from: baseAddress.assumingMemoryBound(to: Int16.self), count: frameCount)
        }

        queuedPlaybackFrames += frameCount
        totalScheduledFrames += frameCount
        let gen = itemGeneration
        playerNode.scheduleBuffer(sourceBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Drop stale callbacks from previous items/clears
                guard gen == self.itemGeneration else {
                    Self.logger.info("Dropping stale callback: gen=\(gen) current=\(self.itemGeneration)")
                    return
                }
                self.queuedPlaybackFrames = max(0, self.queuedPlaybackFrames - frameCount)
                self.consumedFrames += frameCount
                self.drainPendingPlayback(force: false)
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    // MARK: - Audio Graph

    private func configureAudioGraph(resetPlaybackState: Bool) throws {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
        playerNode.stop()
        playerNode.reset()

        // Reset queue accounting whenever the player node is reset. Scheduled buffer
        // callbacks do not fire after a reset, so keeping the old counters causes
        // future audio to stop scheduling.
        queuedPlaybackFrames = 0
        isPlaybackPrimed = false

        if resetPlaybackState {
            pendingPlaybackData.removeAll(keepingCapacity: true)
        }

        let inputNode = engine.inputNode
        if !inputNode.isVoiceProcessingEnabled {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                Self.logger.info("Enabled voice processing on the input node.")
            } catch {
                Self.logger.error("Failed to enable voice processing on the input node: \(error.localizedDescription, privacy: .public)")
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            Self.logger.error("Input format is invalid (rate=\(inputFormat.sampleRate, privacy: .public), ch=\(inputFormat.channelCount, privacy: .public)).")
            throw NSError(domain: "AudioStreamCoordinator", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid input audio format."])
        }

        captureConverter = AVAudioConverter(from: inputFormat, to: pcm16Mono24k)

        engine.connect(playerNode, to: engine.mainMixerNode, format: pcm16Mono24k)
        engine.connect(silenceFiller.node, to: engine.mainMixerNode, format: pcm16Mono24k)

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let data = self.convertInputBuffer(buffer) else { return }

            Task(priority: .userInitiated) {
                await self.inputSink?(data)
            }
        }

        engine.prepare()
        try engine.start()
        playerNode.play()

        Self.logger.info("Input format: rate=\(inputFormat.sampleRate, privacy: .public) ch=\(inputFormat.channelCount, privacy: .public) fmt=\(String(describing: inputFormat.commonFormat), privacy: .public)")
        Self.logger.info("Output format: rate=\(outputFormat.sampleRate, privacy: .public) ch=\(outputFormat.channelCount, privacy: .public) fmt=\(String(describing: outputFormat.commonFormat), privacy: .public)")
        Self.logger.info("Player connection format: rate=\(self.pcm16Mono24k.sampleRate, privacy: .public) ch=\(self.pcm16Mono24k.channelCount, privacy: .public) fmt=\(String(describing: self.pcm16Mono24k.commonFormat), privacy: .public)")
        Self.logger.info("Input tap buffer size: 1024 frames")
        Self.logger.info("Engine running: \(self.engine.isRunning, privacy: .public), player playing: \(self.playerNode.isPlaying, privacy: .public)")
        if !engine.isRunning {
            throw NSError(
                domain: "AudioStreamCoordinator",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Audio engine failed to remain running after start."]
            )
        }
    }

    private func startObservingEngineConfigurationChanges() {
        guard engineConfigurationObserver == nil else { return }

        engineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEngineConfigurationChange()
            }
        }
    }

    private func convertInputBuffer(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let captureConverter else { return nil }

        let ratio = pcm16Mono24k.sampleRate / buffer.format.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: pcm16Mono24k, frameCapacity: targetCapacity) else {
            return nil
        }

        var sourceBuffer: AVAudioPCMBuffer? = buffer
        var conversionError: NSError?

        let status = captureConverter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if let currentBuffer = sourceBuffer {
                outStatus.pointee = .haveData
                sourceBuffer = nil
                return currentBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        guard status != .error, conversionError == nil else { return nil }
        guard let channelData = convertedBuffer.int16ChannelData else { return nil }

        let byteCount = Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: channelData[0], count: byteCount)
    }
}
