import Foundation
import OSLog
import SwiftAgents
import SwiftUI

/// A timestamped status line. Carries its own identity because log lines can
/// repeat verbatim (e.g. "Session configured" from both session.created and
/// session.updated), which would collide under `id: \.self` in a `List`.
struct StatusLine: Identifiable {
    let id = UUID()
    let text: String
}

@MainActor
final class TranslatorViewModel: ObservableObject {
    private static let logger = Logger(subsystem: "LiveTranslator", category: "TranslatorViewModel")

    @Published private(set) var connectionState: ConnectionState = .idle
    /// Rolling transcript of what the model heard (source language).
    @Published private(set) var sourceText: String = ""
    /// Rolling transcript of the translation (target language). This is the
    /// text the user reads while listening to the translated audio.
    @Published private(set) var translationText: String = ""
    @Published private(set) var statusMessages: [StatusLine] = []
    @Published var targetLanguage: TargetLanguage = .english {
        didSet {
            guard oldValue != targetLanguage else { return }
            applyTargetLanguageChange()
        }
    }

    let configuration: AppConfiguration

    /// The continuous translation stream has no utterance boundaries, so we
    /// keep a rolling window rather than letting the transcript grow forever.
    private static let maxTranscriptCharacters = 4000

    private let audioCoordinator = AudioStreamCoordinator()
    private var model: OpenAIRealtimeTranslationModel?
    private var eventsTask: Task<Void, Never>?

    init(configuration: AppConfiguration) {
        self.configuration = configuration

        audioCoordinator.onRouteChangeStatus = { [weak self] message in
            self?.appendStatus(message)
        }
    }

    var canStart: Bool {
        configuration.startupIssue == nil && connectionState == .idle
    }

    var canStop: Bool {
        connectionState.isLive || connectionState.isBusy
    }

    var hasTranscript: Bool {
        !sourceText.isEmpty || !translationText.isEmpty
    }

    func start() async {
        guard canStart else { return }
        guard let apiKey = configuration.apiKey else {
            appendStatus(configuration.startupIssue ?? "Missing API key.")
            connectionState = .failed("Missing API key.")
            return
        }

        connectionState = .starting
        appendStatus("Configuring microphone session.")
        do {
            let diagnostics = try await audioCoordinator.configure { [weak self] data in
                await self?.handleCapturedAudio(data)
            }
            for line in diagnostics.summaryLines {
                appendStatus(line)
            }

            let model = OpenAIRealtimeTranslationModel(
                openAI: OpenAI(apiKey: apiKey),
                model: configuration.translateModel
            )
            self.model = model

            appendStatus("Connecting with model \(configuration.translateModel).")
            let events = try await model.connect(configuration: translationConfiguration())

            eventsTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await event in events {
                        handle(event)
                    }
                } catch {
                    appendStatus("⚠️ Stream ended: \(error.localizedDescription)")
                    await stop()
                }
            }

            try audioCoordinator.startEngine()
            connectionState = .listening
            appendStatus("Listening. Target: \(targetLanguage.displayName).")
        } catch {
            await teardownAfterFailure(reason: error.localizedDescription)
        }
    }

    private func translationConfiguration() -> RealtimeTranslationConfiguration {
        RealtimeTranslationConfiguration(
            targetLanguage: targetLanguage.rawValue,
            transcriptionModel: configuration.transcriptionModel,
            inputNoiseReduction: "near_field"
        )
    }

    func stop() async {
        guard canStop else { return }
        connectionState = .stopping
        appendStatus("Stopping.")
        eventsTask?.cancel()
        eventsTask = nil
        if let model {
            await model.disconnect()
        }
        model = nil
        audioCoordinator.stop()
        connectionState = .idle
        appendStatus("Stopped.")
    }

    func clearTranscript() {
        sourceText = ""
        translationText = ""
    }

    func togglePreferredOutputRoute() {
        let new: AudioSessionController.OutputRoute = audioCoordinator.preferredOutputRoute == .headset
            ? .speaker : .headset
        do {
            try audioCoordinator.setPreferredOutputRoute(new)
            appendStatus("Audio route → \(new.title).")
        } catch {
            appendStatus("Failed to switch route: \(error.localizedDescription)")
        }
    }

    var currentOutputRoute: AudioSessionController.OutputRoute {
        audioCoordinator.currentOutputRoute
    }

    // MARK: - Private

    private func handleCapturedAudio(_ data: Data) async {
        guard let model else { return }
        do {
            try await model.sendAudio(data)
        } catch {
            Self.logger.error("Failed to send audio chunk: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyTargetLanguageChange() {
        guard let model else { return }
        appendStatus("Target → \(targetLanguage.displayName).")
        Task { [config = translationConfiguration()] in
            try? await model.updateConfiguration(config)
        }
    }

    private func teardownAfterFailure(reason: String) async {
        eventsTask?.cancel()
        eventsTask = nil
        if let model {
            await model.disconnect()
        }
        model = nil
        audioCoordinator.stop()
        connectionState = .failed(reason)
        appendStatus("Failed: \(reason)")
    }

    private func handle(_ event: RealtimeTranslationEvent) {
        switch event {
            case .sessionConfigured:
                appendStatus("Session configured.")

            case let .audioDelta(chunk):
                audioCoordinator.enqueueOutputPCM16(chunk)

            case let .sourceTranscriptDelta(text):
                sourceText = appendCapped(sourceText, text)

            case let .translationTranscriptDelta(text):
                translationText = appendCapped(translationText, text)

            case let .error(detail):
                let code = detail.code.map { "[\($0)] " } ?? ""
                appendStatus("⚠️ \(code)\(detail.message)")

            case let .raw(payload):
                if let type = payload["type"] {
                    Self.logger.debug("Unhandled translation event: \(String(describing: type), privacy: .public)")
                }
        }
    }

    /// Append a delta, trimming from the front (at a word boundary) once the
    /// rolling window is exceeded so the transcript stays bounded.
    private func appendCapped(_ existing: String, _ delta: String) -> String {
        var combined = existing + delta
        if combined.count > Self.maxTranscriptCharacters {
            let overflow = combined.count - Self.maxTranscriptCharacters
            let dropIndex = combined.index(combined.startIndex, offsetBy: overflow)
            combined = String(combined[dropIndex...])
            if let space = combined.firstIndex(of: " ") {
                combined = String(combined[combined.index(after: space)...])
            }
        }
        return combined
    }

    private func appendStatus(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        statusMessages.append(StatusLine(text: "[\(timestamp)] \(message)"))
        Self.logger.info("\(message, privacy: .public)")
        if statusMessages.count > 40 {
            statusMessages.removeFirst(statusMessages.count - 40)
        }
    }
}
