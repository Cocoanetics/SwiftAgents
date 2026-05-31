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

    private static let logger = Logger(subsystem: "LiveTranslator", category: "AudioPlayback")
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    let sessionController: AudioSessionController
    private var engineConfigurationObserver: NSObjectProtocol?

    private var captureConverter: AVAudioConverter?
    private var inputSink: (@Sendable (Data) async -> Void)?
    private var pendingPlaybackData = Data()
    private var queuedPlaybackFrames: Int = 0
    private var isPlaybackPrimed = false
    private var isHandlingEngineConfigurationChange = false

    var onRouteChanged: (@MainActor () -> Void)?
    var onRouteChangeStatus: (@MainActor (String) -> Void)?

    private let pcm16Mono24k = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24000,
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
        engine.attach(playerNode)

        self.sessionController.onRouteChange = { [weak self] reason in
            self?.handleRouteChange(reason: reason)
        }
        startObservingEngineConfigurationChanges()
    }

    /// Configure the audio session (microphone permission, category, mode).
    /// Does NOT start the engine yet — call `startEngine()` after.
    func configure(onInputPCM16: @escaping @Sendable (Data) async -> Void) async throws -> AudioSessionDiagnostics {
        inputSink = onInputPCM16
        return try await sessionController.configureForRealtimeConversation()
    }

    /// Build the audio graph and start capture + playback.
    func startEngine() throws {
        guard inputSink != nil else {
            Self.logger.error("startEngine called before configure, no input sink set.")
            throw AudioStartError.notConfigured
        }
        try configureAudioGraph(resetPlaybackState: true)
        Self.logger.info("Audio engine started.")
    }

    /// Tear everything down.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        playerNode.reset()
        engine.stop()
        engine.reset()
        inputSink = nil
        pendingPlaybackData.removeAll(keepingCapacity: false)
        queuedPlaybackFrames = 0
        isPlaybackPrimed = false
        sessionController.deactivate()
    }

    // MARK: - Playback Control

    func clearPlayback() {
        playerNode.stop()
        playerNode.reset()
        pendingPlaybackData.removeAll(keepingCapacity: true)
        queuedPlaybackFrames = 0
        isPlaybackPrimed = false
        if engine.isRunning {
            playerNode.play()
        }
    }

    var preferredOutputRoute: AudioSessionController.OutputRoute {
        sessionController.preferredOutputRoute
    }

    var currentOutputRoute: AudioSessionController.OutputRoute {
        sessionController.currentOutputRoute
    }

    func setPreferredOutputRoute(_ route: AudioSessionController.OutputRoute) throws {
        try sessionController.setPreferredOutputRoute(route)
    }

    func flushPlayback() {
        drainPendingPlayback(force: true)
    }

    func enqueueOutputPCM16(_ data: Data) {
        guard engine.isRunning else {
            Self.logger.error("Dropping output audio chunk because engine is not running.")
            return
        }

        let alignedByteCount = data.count - (data.count % bytesPerFrame)
        guard alignedByteCount > 0 else {
            Self.logger.error("Received output audio chunk without a full PCM16 frame.")
            return
        }

        pendingPlaybackData.append(data.prefix(alignedByteCount))
        drainPendingPlayback(force: false)
    }

    // MARK: - Route Change Handling

    private func handleRouteChange(reason _: AVAudioSession.RouteChangeReason) {
        onRouteChanged?()

        guard inputSink != nil else {
            Self.logger.info("Route change observed before audio input was configured.")
            return
        }

        let message = engine.isRunning
            ? "Adopted external audio route change without rebuilding the graph."
            : "Observed audio route change while the engine reported inactive; leaving the graph untouched."
        Self.logger.info("\(message, privacy: .public)")
        onRouteChangeStatus?(message)
    }

    private func handleEngineConfigurationChange() {
        guard inputSink != nil else { return }
        guard !isHandlingEngineConfigurationChange else { return }

        isHandlingEngineConfigurationChange = true
        defer { isHandlingEngineConfigurationChange = false }

        let message = "Audio engine configuration changed."
        Self.logger.info("\(message, privacy: .public)")
        onRouteChangeStatus?(message)

        if engine.isRunning {
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
            Self.logger.error(
                """
                Failed to rebuild audio graph after configuration change: \
                \(error.localizedDescription, privacy: .public)
                """
            )
            onRouteChangeStatus?("Failed to recover audio after configuration change: \(error.localizedDescription)")
        }
    }

    // MARK: - Playback Drain

    private func drainPendingPlayback(force: Bool) {
        guard engine.isRunning else { return }

        let pendingFrames = pendingPlaybackData.count / bytesPerFrame
        if !isPlaybackPrimed {
            if !force, pendingFrames < prerollFrames {
                return
            }
            isPlaybackPrimed = true
        }

        while pendingPlaybackData.count >= minimumScheduleFrames * bytesPerFrame
            || (force && !pendingPlaybackData.isEmpty) {
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
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: pcm16Mono24k,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = sourceBuffer.int16ChannelData else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            channelData[0].update(from: baseAddress.assumingMemoryBound(to: Int16.self), count: frameCount)
        }

        queuedPlaybackFrames += frameCount
        playerNode.scheduleBuffer(sourceBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                queuedPlaybackFrames = max(0, queuedPlaybackFrames - frameCount)
                drainPendingPlayback(force: false)
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

        queuedPlaybackFrames = 0
        isPlaybackPrimed = false

        if resetPlaybackState {
            pendingPlaybackData.removeAll(keepingCapacity: true)
        }

        let inputNode = engine.inputNode
        // Voice processing (VPIO) is deliberately left OFF. It's built for the
        // near-field call case and is coupled to the Bluetooth HFP duplex —
        // enabling it tends to drag the route back onto the AirPod mic, which
        // defeats the whole point of capturing the room with the built-in mic.
        // Translated audio plays to sealed in-ear AirPods, so echo back into
        // the phone mic is negligible and AEC isn't needed.
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            Self.logger.error(
                """
                Input format is invalid (rate=\(inputFormat.sampleRate, privacy: .public), \
                ch=\(inputFormat.channelCount, privacy: .public)).
                """
            )
            throw NSError(domain: "AudioStreamCoordinator", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid input audio format."])
        }

        captureConverter = AVAudioConverter(from: inputFormat, to: pcm16Mono24k)

        engine.connect(playerNode, to: engine.mainMixerNode, format: pcm16Mono24k)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let data = convertInputBuffer(buffer) else { return }

            Task(priority: .userInitiated) {
                await self.inputSink?(data)
            }
        }

        engine.prepare()
        try engine.start()
        playerNode.play()

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
