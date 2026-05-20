@preconcurrency import AVFAudio
import Foundation
import OSLog

/// Plays ambient typing sounds during prolonged silence (e.g. tool calls)
/// to signal the agent is still working. Mirrors the "silence filler" pattern
/// from the openclaw voice-call plugin.
///
/// The typing audio is loaded from a bundled raw PCM16 file (`typing.raw`,
/// mono 24 kHz) that was converted from the openclaw asset via ffmpeg.
///
/// Usage:
///   silenceFiller.start()   // begin threshold timer
///   silenceFiller.stop()    // cancel timer / stop sound immediately
@MainActor
final class SilenceFiller {
    private static let logger = Logger(subsystem: "RealtimeVoiceAgent", category: "SilenceFiller")

    let node = AVAudioPlayerNode()

    /// Milliseconds of silence before the typing sound begins.
    let thresholdMs: Int

    private let format: AVAudioFormat
    private var delayTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private(set) var isPlaying = false

    /// Lazily loaded typing clip from the bundle.
    private var typingClip: AVAudioPCMBuffer?

    init(format: AVAudioFormat, thresholdMs: Int = 3500) {
        self.format = format
        self.thresholdMs = thresholdMs
        node.volume = 0.7
    }

    /// Begin the silence timer. If the threshold elapses without `stop()`,
    /// a looping typing sound starts playing through `node`.
    /// - Parameter immediate: If `true`, skip the threshold timer and start playback right away
    ///   (e.g. when a tool call begins).
    func start(immediate: Bool = false) {
        stop()
        if immediate {
            playLoop()
            return
        }
        delayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(self?.thresholdMs ?? 3500))
            guard !Task.isCancelled, let self else { return }
            self.playLoop()
        }
        Self.logger.info("Silence filler armed (threshold: \(self.thresholdMs)ms)")
    }

    /// Cancel the timer and immediately stop any playing filler audio.
    func stop() {
        let wasArmedOrPlaying = delayTask != nil || isPlaying
        delayTask?.cancel()
        delayTask = nil
        loopTask?.cancel()
        loopTask = nil
        if isPlaying {
            node.stop()
            node.reset()
            isPlaying = false
            Self.logger.info("Silence filler stopped (was playing)")
        } else if wasArmedOrPlaying {
            Self.logger.info("Silence filler disarmed")
        }
    }

    // MARK: - Playback Loop

    private func playLoop() {
        guard node.engine?.isRunning == true else {
            Self.logger.warning("Cannot start filler: engine not running")
            return
        }

        guard let clip = loadTypingClip() else {
            Self.logger.error("No typing clip available")
            return
        }

        isPlaying = true
        node.play()
        Self.logger.info("Silence filler started playing")

        let clipDurationMs = Int(Double(clip.frameLength) / format.sampleRate * 1000)

        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard !Task.isCancelled else { break }

                await self.node.scheduleBuffer(clip)

                // Sleep for the clip duration, then loop
                try? await Task.sleep(for: .milliseconds(clipDurationMs))
                guard !Task.isCancelled else { break }

                // Brief pause between loops
                try? await Task.sleep(for: .milliseconds(Int.random(in: 200...500)))
            }
        }
    }

    // MARK: - Asset Loading

    /// Load the bundled `typing.raw` file (PCM16 mono 24 kHz) into an `AVAudioPCMBuffer`.
    private func loadTypingClip() -> AVAudioPCMBuffer? {
        if let cached = typingClip { return cached }

        guard let url = Bundle.main.url(forResource: "typing", withExtension: "raw") else {
            Self.logger.error("typing.raw not found in bundle")
            return nil
        }

        guard let rawData = try? Data(contentsOf: url) else {
            Self.logger.error("Failed to read typing.raw")
            return nil
        }

        let bytesPerFrame = MemoryLayout<Int16>.size // mono
        let frameCount = rawData.count / bytesPerFrame
        guard frameCount > 0 else {
            Self.logger.error("typing.raw is empty")
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            Self.logger.error("Failed to create PCM buffer for typing clip")
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = buffer.int16ChannelData else {
            Self.logger.error("No int16 channel data in buffer")
            return nil
        }

        rawData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            channelData[0].update(from: baseAddress.assumingMemoryBound(to: Int16.self), count: frameCount)
        }

        Self.logger.info("Loaded typing.raw: \(frameCount) frames (\(String(format: "%.1f", Double(frameCount) / self.format.sampleRate))s)")
        typingClip = buffer
        return buffer
    }
}
