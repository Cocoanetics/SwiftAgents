import AVFAudio
import Foundation
import OSLog

struct AudioSessionDiagnostics {
    let requestedMode: String
    let deviceEchoCancellationAvailable: Bool
    let deviceEchoCancellationEnabled: Bool
    let actualMode: String
    let sampleRate: Double
    let inputRoute: String
    let outputRoute: String

    var summaryLines: [String] {
        [
            "Audio session mode requested: \(requestedMode)",
            "Echo cancellation available: \(deviceEchoCancellationAvailable ? "yes" : "no")",
            "Echo cancellation enabled: \(deviceEchoCancellationEnabled ? "yes" : "no")",
            "Audio session actual mode: \(actualMode)",
            String(format: "Audio sample rate: %.0f Hz", sampleRate),
            "Input route: \(inputRoute)",
            "Output route: \(outputRoute)"
        ]
    }
}

final class AudioSessionController {
    private static let logger = Logger(subsystem: "LiveTranslator", category: "AudioSession")

    /// The output destination the user prefers.
    /// - `headset`: AirPods / wired headphones if available, otherwise earpiece. Default.
    /// - `speaker`: Force the built-in speaker (useful for testing without headphones).
    enum OutputRoute: String {
        case headset
        case speaker

        var title: String {
            switch self {
                case .headset:
                    return "Headset"
                case .speaker:
                    return "Speaker"
            }
        }
    }

    enum Error: LocalizedError {
        case microphonePermissionDenied

        var errorDescription: String? {
            switch self {
                case .microphonePermissionDenied:
                    return "Microphone permission was denied."
            }
        }
    }

    private let session = AVAudioSession.sharedInstance()
    private(set) var preferredOutputRoute: OutputRoute = .headset
    private(set) var currentOutputRoute: OutputRoute = .headset

    var onRouteChange: (@MainActor (AVAudioSession.RouteChangeReason) -> Void)?

    private var routeChangeObserver: NSObjectProtocol?

    func configureForRealtimeConversation() async throws -> AudioSessionDiagnostics {
        let hasPermission = await requestRecordPermission()
        guard hasPermission else {
            throw Error.microphonePermissionDenied
        }

        let requestedMode: AVAudioSession.Mode = .default
        let echoCancelledInputAvailable: Bool = if #available(iOS 18.2, *) {
            session.isEchoCancelledInputAvailable
        } else {
            false
        }

        // We want a SPLIT route: capture the room with the built-in mic, but
        // play the translation privately to AirPods.
        //
        // The Bluetooth call profile (HFP, enabled by `.allowBluetoothHFP` +
        // `.voiceChat`) is bidirectional, so it forces the AirPod's *own* mic
        // as input — which only hears the wearer. A2DP is output-only and
        // high quality, so using `.allowBluetoothA2DP` (and NOT HFP) lets the
        // AirPods be the output while the input falls back to the built-in
        // mic. `.default` mode (not `.voiceChat`) keeps the system from
        // forcing the HFP duplex back on.
        let categoryOptions: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .allowAirPlay]
        try session.setCategory(.playAndRecord, mode: .default, options: categoryOptions)
        try session.setPreferredSampleRate(24000)
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true, options: [])
        try applyPreferredOutputRoute()
        applyPreferredInput()

        startObservingRouteChanges()

        let currentRoute = session.currentRoute
        let inputRoute = currentRoute.inputs.map(\.portType.rawValue).joined(separator: ", ")
        let outputRoute = currentRoute.outputs.map(\.portType.rawValue).joined(separator: ", ")
        currentOutputRoute = route(for: currentRoute)
        let echoCancelledInputEnabled: Bool = if #available(iOS 18.2, *) {
            session.isEchoCancelledInputEnabled
        } else {
            false
        }

        return AudioSessionDiagnostics(
            requestedMode: requestedMode.rawValue,
            deviceEchoCancellationAvailable: echoCancelledInputAvailable,
            deviceEchoCancellationEnabled: echoCancelledInputEnabled,
            actualMode: session.mode.rawValue,
            sampleRate: session.sampleRate,
            inputRoute: inputRoute.isEmpty ? "none" : inputRoute,
            outputRoute: outputRoute.isEmpty ? "none" : outputRoute
        )
    }

    func setPreferredOutputRoute(_ route: OutputRoute) throws {
        preferredOutputRoute = route
        currentOutputRoute = route
        try session.setActive(true, options: [])
        try applyPreferredOutputRoute()
    }

    func deactivate() {
        stopObservingRouteChanges()
        try? session.overrideOutputAudioPort(.none)
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        currentOutputRoute = .headset
    }

    func syncCurrentRouteFromHardware() {
        let newRoute = route(for: session.currentRoute)
        if newRoute != currentOutputRoute {
            Self.logger.info("Observed hardware route change to \(newRoute.rawValue, privacy: .public).")
            currentOutputRoute = newRoute
        }
    }

    private func route(for routeDescription: AVAudioSessionRouteDescription) -> OutputRoute {
        // Treat anything that is NOT the built-in speaker as "headset" — that
        // covers AirPods, wired headphones, the receiver, etc. The toggle only
        // exists so the user can force the loud speaker if they want to test
        // without headphones.
        routeDescription.outputs.contains { $0.portType == .builtInSpeaker } ? .speaker : .headset
    }

    /// Force the built-in mic as the capture source so we hear the room rather
    /// than the AirPod's mic. Bluetooth A2DP exposes no input, so the only
    /// candidates are the built-in mic (and wired headset mics); we explicitly
    /// pick the built-in one. Re-applied on route changes since reconnecting a
    /// device can reset the preferred input.
    func applyPreferredInput() {
        guard let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
            Self.logger.info("Built-in mic not found among available inputs.")
            return
        }
        do {
            try session.setPreferredInput(builtInMic)
            Self.logger.info("Preferred input set to built-in mic.")
        } catch {
            Self.logger.error("Failed to set preferred input: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyPreferredOutputRoute() throws {
        switch preferredOutputRoute {
            case .headset:
                try session.overrideOutputAudioPort(.none)
            case .speaker:
                try session.overrideOutputAudioPort(.speaker)
        }
    }

    private func startObservingRouteChanges() {
        stopObservingRouteChanges()

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }

            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) ?? .unknown

            let currentRoute = session.currentRoute
            let inputDesc = currentRoute.inputs.map(\.portType.rawValue).joined(separator: ", ")
            let outputDesc = currentRoute.outputs.map(\.portType.rawValue).joined(separator: ", ")
            Self.logger.info(
                """
                Route changed (reason: \(reason.rawValue, privacy: .public)). \
                Input: \(inputDesc, privacy: .public), Output: \(outputDesc, privacy: .public)
                """
            )

            switch reason {
                case .override, .categoryChange, .routeConfigurationChange, .newDeviceAvailable, .oldDeviceUnavailable:
                    syncCurrentRouteFromHardware()
                    // A device (dis)connecting can reset the preferred input back
                    // to the Bluetooth mic — re-pin the built-in mic.
                    applyPreferredInput()
                default:
                    break
            }

            Task { @MainActor [weak self] in
                self?.onRouteChange?(reason)
            }
        }
    }

    private func stopObservingRouteChanges() {
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
    }

    private func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
