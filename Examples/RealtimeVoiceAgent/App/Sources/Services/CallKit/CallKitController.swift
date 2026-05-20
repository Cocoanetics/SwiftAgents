import AVFAudio
import CallKit
import Foundation
import OSLog

final class CallKitController: NSObject {
    private static let logger = Logger(subsystem: "RealtimeVoiceAgent", category: "CallKit")

    private let provider: CXProvider
    private let callController = CXCallController()
    private let isSimulationMode: Bool

    var onStartCallRequested: (@MainActor () async throws -> Void)?
    var onEndCallRequested: (@MainActor () async -> Void)?
    var onAudioSessionActivated: (@MainActor () -> Void)?
    var onAudioSessionDeactivated: (@MainActor () -> Void)?

    private(set) var activeCallUUID: UUID?

    override init() {
        self.isSimulationMode = ProcessInfo.processInfo.arguments.contains("UITEST_CALLKIT_SIMULATION")
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        configuration.iconTemplateImageData = nil

        self.provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
        let handleTypesDescription = configuration.supportedHandleTypes.map(\.rawValue).description
        Self.logger.info("Configured CallKit provider: handleTypes=\(handleTypesDescription, privacy: .public) maxGroups=\(configuration.maximumCallGroups, privacy: .public) maxCallsPerGroup=\(configuration.maximumCallsPerCallGroup, privacy: .public) includesRecents=\(configuration.includesCallsInRecents, privacy: .public)")
    }

    deinit {
        Self.logger.info("Invalidating CallKit provider.")
        provider.invalidate()
    }

    var hasActiveCall: Bool {
        activeCallUUID != nil
    }

    func startCall(handle: String) async throws {
        guard activeCallUUID == nil else { return }

        if isSimulationMode {
            let uuid = UUID()
            activeCallUUID = uuid
            Self.logger.info("Simulating CallKit start call for \(handle, privacy: .public)")
            try await onStartCallRequested?()
            return
        }

        let uuid = UUID()
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        action.isVideo = false
        let transaction = CXTransaction(action: action)

        Self.logger.info("Submitting CallKit start-call request: uuid=\(uuid.uuidString, privacy: .public) handle=\(handle, privacy: .public)")
        try await request(transaction)
        activeCallUUID = uuid
        Self.logger.info("Requested CallKit start call for \(handle, privacy: .public)")
        logProviderState(context: "after startCall request", callUUID: uuid)
    }

    func endCall() async {
        guard let uuid = activeCallUUID else { return }

        if isSimulationMode {
            activeCallUUID = nil
            Self.logger.info("Simulating CallKit end call.")
            await onEndCallRequested?()
            return
        }

        let action = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: action)

        do {
            Self.logger.info("Submitting CallKit end-call request: uuid=\(uuid.uuidString, privacy: .public)")
            try await request(transaction)
            Self.logger.info("Requested CallKit end call.")
            logProviderState(context: "after endCall request", callUUID: uuid)
        } catch {
            Self.logger.error("Failed to request CallKit end call: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reportCallEndedIfNeeded(reason: CXCallEndedReason = .remoteEnded) {
        guard let uuid = activeCallUUID else { return }
        Self.logger.info("Reporting CallKit call ended: uuid=\(uuid.uuidString, privacy: .public) reason=\(self.describeEndedReason(reason), privacy: .public)")
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        activeCallUUID = nil
        logProviderState(context: "after reportCallEndedIfNeeded", callUUID: uuid)
    }

    private func request(_ transaction: CXTransaction) async throws {
        let actionsDescription = transaction.actions.map(describeAction).joined(separator: ", ")
        Self.logger.info("Requesting CallKit transaction with \(transaction.actions.count, privacy: .public) action(s): \(actionsDescription, privacy: .public)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            callController.request(transaction) { error in
                if let error {
                    Self.logger.error("CallKit transaction request failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                } else {
                    Self.logger.info("CallKit transaction request completed successfully.")
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func logProviderState(context: String, callUUID: UUID? = nil) {
        let pendingTransactions = provider.pendingTransactions
        let pendingSummary = pendingTransactions.map { transaction in
            transaction.actions.map(describeAction).joined(separator: " | ")
        }.joined(separator: " || ")

        var callActionSummary = "n/a"
        if let callUUID {
            let startCount = provider.pendingCallActions(of: CXStartCallAction.self, withCall: callUUID).count
            let endCount = provider.pendingCallActions(of: CXEndCallAction.self, withCall: callUUID).count
            let heldCount = provider.pendingCallActions(of: CXSetHeldCallAction.self, withCall: callUUID).count
            let mutedCount = provider.pendingCallActions(of: CXSetMutedCallAction.self, withCall: callUUID).count
            callActionSummary = "start=\(startCount) end=\(endCount) held=\(heldCount) muted=\(mutedCount)"
        }

        Self.logger.info("CallKit provider state [\(context, privacy: .public)]: activeUUID=\(self.activeCallUUID?.uuidString ?? "nil", privacy: .public) pendingTransactions=\(pendingTransactions.count, privacy: .public) pendingActions=\(pendingSummary, privacy: .public) pendingForCall=\(callActionSummary, privacy: .public)")
    }

    private func describeAction(_ action: CXAction) -> String {
        if let action = action as? CXStartCallAction {
            return "CXStartCallAction(uuid: \(action.callUUID.uuidString), handle: \(action.handle.value), video: \(action.isVideo))"
        }
        if let action = action as? CXEndCallAction {
            return "CXEndCallAction(uuid: \(action.callUUID.uuidString))"
        }
        if let action = action as? CXSetHeldCallAction {
            return "CXSetHeldCallAction(uuid: \(action.callUUID.uuidString), onHold: \(action.isOnHold))"
        }
        if let action = action as? CXSetMutedCallAction {
            return "CXSetMutedCallAction(uuid: \(action.callUUID.uuidString), muted: \(action.isMuted))"
        }
        if let action = action as? CXAnswerCallAction {
            return "CXAnswerCallAction(uuid: \(action.callUUID.uuidString))"
        }
        return String(describing: type(of: action))
    }

    private func describeEndedReason(_ reason: CXCallEndedReason) -> String {
        switch reason {
        case .failed:
            return "failed"
        case .remoteEnded:
            return "remoteEnded"
        case .unanswered:
            return "unanswered"
        case .answeredElsewhere:
            return "answeredElsewhere"
        case .declinedElsewhere:
            return "declinedElsewhere"
        @unknown default:
            return "unknown(\(reason.rawValue))"
        }
    }
}

extension CallKitController: CXProviderDelegate {
    func providerDidBegin(_ provider: CXProvider) {
        Self.logger.info("CallKit provider did begin.")
        logProviderState(context: "providerDidBegin", callUUID: activeCallUUID)
    }

    func provider(_ provider: CXProvider, execute transaction: CXTransaction) -> Bool {
        let actionsDescription = transaction.actions.map(describeAction).joined(separator: ", ")
        Self.logger.info("CallKit provider asked to execute transaction with \(transaction.actions.count, privacy: .public) action(s): \(actionsDescription, privacy: .public)")
        logProviderState(context: "provider.execute", callUUID: activeCallUUID)
        return false
    }

    func providerDidReset(_ provider: CXProvider) {
        Self.logger.info("CallKit provider reset.")
        logProviderState(context: "providerDidReset(before clear)", callUUID: activeCallUUID)
        activeCallUUID = nil

        Task { @MainActor [onEndCallRequested] in
            await onEndCallRequested?()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Self.logger.info("CallKit perform start action: \(self.describeAction(action), privacy: .public)")
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        logProviderState(context: "provider.perform start(before async work)", callUUID: action.callUUID)

        Task { @MainActor [weak self] in
            guard let self else {
                action.fail()
                return
            }

            do {
                try await self.onStartCallRequested?()
                self.activeCallUUID = action.callUUID
                provider.reportOutgoingCall(with: action.callUUID, connectedAt: Date())
                action.fulfill()
                self.logProviderState(context: "provider.perform start(fulfilled)", callUUID: action.callUUID)
            } catch {
                Self.logger.error("CallKit start call failed: \(error.localizedDescription, privacy: .public)")
                self.activeCallUUID = nil
                action.fail()
                self.logProviderState(context: "provider.perform start(failed)", callUUID: action.callUUID)
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Self.logger.info("CallKit perform end action: \(self.describeAction(action), privacy: .public)")
        logProviderState(context: "provider.perform end(before async work)", callUUID: action.callUUID)
        Task { @MainActor [weak self] in
            guard let self else {
                action.fail()
                return
            }

            self.activeCallUUID = nil
            await self.onEndCallRequested?()
            action.fulfill()
            self.logProviderState(context: "provider.perform end(fulfilled)", callUUID: action.callUUID)
        }
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        Self.logger.error("CallKit action timed out: \(self.describeAction(action), privacy: .public)")
        logProviderState(context: "provider.timedOut", callUUID: (action as? CXCallAction)?.callUUID)
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        let outputs = audioSession.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ", ")
        let inputs = audioSession.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ", ")
        Self.logger.info("CallKit did activate audio session. category=\(audioSession.category.rawValue, privacy: .public) mode=\(audioSession.mode.rawValue, privacy: .public) sampleRate=\(audioSession.sampleRate, privacy: .public) input=\(inputs, privacy: .public) output=\(outputs, privacy: .public)")
        Task { @MainActor [weak self] in
            self?.onAudioSessionActivated?()
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        let outputs = audioSession.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ", ")
        let inputs = audioSession.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ", ")
        Self.logger.info("CallKit did deactivate audio session. category=\(audioSession.category.rawValue, privacy: .public) mode=\(audioSession.mode.rawValue, privacy: .public) sampleRate=\(audioSession.sampleRate, privacy: .public) input=\(inputs, privacy: .public) output=\(outputs, privacy: .public)")
        logProviderState(context: "provider.didDeactivate", callUUID: activeCallUUID)
        Task { @MainActor [weak self] in
            self?.onAudioSessionDeactivated?()
        }
    }
}
