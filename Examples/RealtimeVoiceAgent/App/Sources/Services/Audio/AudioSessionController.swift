import AVFAudio
import Foundation
import OSLog

struct AudioSessionDiagnostics: Sendable {
    let requestedMode: String
    let deviceEchoCancellationAvailable: Bool
    let deviceEchoCancellationPreferred: Bool
    let deviceEchoCancellationEnabled: Bool
    let actualMode: String
    let sampleRate: Double
    let inputRoute: String
    let outputRoute: String

    var summaryLines: [String] {
        [
            "Audio session mode requested: \(requestedMode)",
            "Device echo cancellation available: \(deviceEchoCancellationAvailable ? "yes" : "no")",
            "Device echo cancellation preferred: \(deviceEchoCancellationPreferred ? "yes" : "no")",
            "Device echo cancellation enabled: \(deviceEchoCancellationEnabled ? "yes" : "no")",
            "Audio session actual mode: \(actualMode)",
            String(format: "Audio sample rate: %.0f Hz", sampleRate),
            "Input route: \(inputRoute)",
            "Output route: \(outputRoute)"
        ]
    }
}

final class AudioSessionController {
    private static let logger = Logger(subsystem: "RealtimeVoiceAgent", category: "AudioSession")

    enum OutputRoute: String, Sendable {
        case phone
        case speaker

        var title: String {
            switch self {
            case .phone:
                return "Phone"
            case .speaker:
                return "Speaker"
            }
        }
    }

    enum Error: LocalizedError {
        case microphonePermissionDenied
        case manualRouteOverrideUnavailable

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone permission was denied."
            case .manualRouteOverrideUnavailable:
                return "Manual route switching is unavailable while CallKit owns the call audio route."
            }
        }
    }

    private let session = AVAudioSession.sharedInstance()
    private(set) var preferredOutputRoute: OutputRoute = .phone
    private(set) var currentOutputRoute: OutputRoute = .phone
    private var manualRouteOverrideEnabled = true

    var isManualRouteOverrideEnabled: Bool {
        manualRouteOverrideEnabled
    }

    /// Called on the main thread when the system changes the audio route.
    /// Used so the audio coordinator can distinguish between external user route changes
    /// and transient system reconfiguration.
    var onRouteChange: ((@MainActor (AVAudioSession.RouteChangeReason) -> Void))?

    private var routeChangeObserver: NSObjectProtocol?

    func configureForRealtimeConversation() async throws -> AudioSessionDiagnostics {
        let hasPermission = await requestRecordPermission()
        guard hasPermission else {
            throw Error.microphonePermissionDenied
        }

        let requestedMode: AVAudioSession.Mode = .voiceChat
        let echoCancelledInputAvailable: Bool
        let echoCancelledInputPreferred: Bool = false

        if #available(iOS 18.2, *) {
            echoCancelledInputAvailable = session.isEchoCancelledInputAvailable
        } else {
            echoCancelledInputAvailable = false
        }

        // Follow Speakerbox more closely for real CallKit calls:
        // configure category + mode early, do not directly activate the session,
        // and avoid extra category options that can confuse CallKit's speaker UI.
        let categoryOptions: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        try session.setCategory(.playAndRecord, options: categoryOptions)
        try session.setMode(.voiceChat)
        if manualRouteOverrideEnabled, session.categoryOptions != categoryOptions {
            try session.setCategory(.playAndRecord, options: categoryOptions)
        }
        try session.setPreferredSampleRate(24_000)
        try session.setPreferredIOBufferDuration(0.02)
        if manualRouteOverrideEnabled {
            // Fallback in-app calls still activate and own the route here.
            try session.setActive(true, options: [])
            try applyPreferredOutputRoute()
        }

        startObservingRouteChanges()

        let currentRoute = session.currentRoute
        let inputRoute = currentRoute.inputs.map(\ .portType.rawValue).joined(separator: ", ")
        let outputRoute = currentRoute.outputs.map(\ .portType.rawValue).joined(separator: ", ")
        currentOutputRoute = route(for: currentRoute)
        let echoCancelledInputEnabled: Bool
        if #available(iOS 18.2, *) {
            echoCancelledInputEnabled = session.isEchoCancelledInputEnabled
        } else {
            echoCancelledInputEnabled = false
        }

        return AudioSessionDiagnostics(
            requestedMode: requestedMode.rawValue,
            deviceEchoCancellationAvailable: echoCancelledInputAvailable,
            deviceEchoCancellationPreferred: echoCancelledInputPreferred,
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
        guard manualRouteOverrideEnabled else {
            throw Error.manualRouteOverrideUnavailable
        }
        try session.setActive(true, options: [])
        try applyPreferredOutputRoute()
    }

    func setManualRouteOverrideEnabled(_ enabled: Bool) {
        manualRouteOverrideEnabled = enabled
    }

    func deactivate() {
        stopObservingRouteChanges()

        if manualRouteOverrideEnabled {
            // App-managed fallback calls own activation and route overrides.
            try? session.overrideOutputAudioPort(.none)
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        } else {
            // Real CallKit calls should let the system deactivate the audio session.
            Self.logger.info("Skipping direct AVAudioSession deactivation because CallKit owns this call audio session.")
        }

        currentOutputRoute = .phone
        manualRouteOverrideEnabled = true
    }

    /// Reads the current hardware output and syncs `currentOutputRoute` to match.
    func syncCurrentRouteFromHardware() {
        let newRoute = route(for: session.currentRoute)
        if newRoute != currentOutputRoute {
            Self.logger.info("Observed hardware route change to \(newRoute.rawValue, privacy: .public); updating current route only. preferred=\(self.preferredOutputRoute.rawValue, privacy: .public) manualOverrideEnabled=\(self.manualRouteOverrideEnabled, privacy: .public)")
            currentOutputRoute = newRoute
        }
    }

    private func route(for routeDescription: AVAudioSessionRouteDescription) -> OutputRoute {
        routeDescription.outputs.contains { $0.portType == .builtInSpeaker } ? .speaker : .phone
    }

    private func applyPreferredOutputRoute() throws {
        switch preferredOutputRoute {
        case .phone:
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

            let reason: AVAudioSession.RouteChangeReason
            if let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               let parsed = AVAudioSession.RouteChangeReason(rawValue: rawReason) {
                reason = parsed
            } else {
                reason = .unknown
            }

            let currentRoute = self.session.currentRoute
            let inputDesc = currentRoute.inputs.map(\ .portType.rawValue).joined(separator: ", ")
            let outputDesc = currentRoute.outputs.map(\ .portType.rawValue).joined(separator: ", ")
            Self.logger.info("Route changed (reason: \(reason.rawValue, privacy: .public)). Input: \(inputDesc, privacy: .public), Output: \(outputDesc, privacy: .public)")

            // Always track the observed hardware route, even when CallKit owns route selection.
            // The difference is only whether the app is allowed to impose its own override.
            switch reason {
            case .override, .categoryChange, .routeConfigurationChange:
                self.syncCurrentRouteFromHardware()
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
