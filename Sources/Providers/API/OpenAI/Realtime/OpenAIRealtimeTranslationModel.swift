import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftMCP

/// WebSocket transport for OpenAI's live speech-to-speech translation model
/// (`gpt-realtime-translate`, endpoint `/v1/realtime/translations`).
///
/// This is a sibling to ``OpenAIRealtimeWebSocketModel`` but deliberately
/// separate: the translations API is a one-way pipeline with its *own* event
/// namespace (`session.update`, `session.input_audio_buffer.append`,
/// `session.input_transcript.delta`, `session.output_transcript.delta`,
/// `session.output_audio.delta`). There is no `response.create`, no tool use,
/// and no turn lifecycle, so it does not fit the `RealtimeModel` /
/// `RealtimeSession` abstractions.
///
/// Usage:
/// ```swift
/// let model = OpenAIRealtimeTranslationModel(openAI: OpenAI(apiKey: key))
/// let events = try await model.connect(
///     configuration: .init(targetLanguage: "en", transcriptionModel: "gpt-realtime-whisper")
/// )
/// // stream microphone PCM16 (mono, 24 kHz):
/// try await model.sendAudio(pcm16Chunk)
/// for try await event in events { /* play audio / show transcripts */ }
/// ```
///
/// - Note: Do not add an `OpenAI-Beta: realtime=v1` header — the GA endpoint
///   rejects it with `beta_api_shape_disabled`.
public actor OpenAIRealtimeTranslationModel {
    private let openAI: OpenAI
    private let session: URLSession
    private let modelIdentifier: String

    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<RealtimeTranslationEvent, Error>.Continuation?

    public init(
        openAI: OpenAI = OpenAI(),
        model: String = "gpt-realtime-translate",
        session: URLSession? = nil
    ) {
        self.openAI = openAI
        modelIdentifier = model

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 600
            configuration.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Open the socket, send the initial `session.update`, and begin streaming
    /// events. Returns the event stream; call ``sendAudio(_:)`` to feed
    /// microphone audio.
    public func connect(
        configuration: RealtimeTranslationConfiguration
    ) async throws -> AsyncThrowingStream<RealtimeTranslationEvent, Error> {
        guard let apiKey = openAI.apiKey, !apiKey.isEmpty else {
            throw APIError.authenticationError("OPENAI_API_KEY is required for realtime translation sessions")
        }

        let request = try websocketRequest(apiKey: apiKey)
        let socketTask = session.webSocketTask(with: request)
        let (stream, continuation) = AsyncThrowingStream<RealtimeTranslationEvent, Error>.makeStream()

        self.socketTask = socketTask
        self.continuation = continuation

        socketTask.resume()
        receiveTask = Task { await receiveLoop() }

        try await sendConfiguration(configuration)
        return stream
    }

    /// Change the session configuration mid-stream (e.g. switch the target
    /// language). Safe to call while audio is flowing.
    public func updateConfiguration(_ configuration: RealtimeTranslationConfiguration) async throws {
        try await sendConfiguration(configuration)
    }

    /// Append a chunk of microphone audio. Expects PCM16, mono, 24 kHz,
    /// little-endian.
    public func sendAudio(_ pcm16: Data) async throws {
        guard let socketTask else { throw RealtimeSessionError.notConnected }
        try await send(AudioAppendEvent(audio: pcm16.base64EncodedString()), over: socketTask)
    }

    public func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        socketTask?.cancel(with: .normalClosure, reason: nil)
        socketTask = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Private

    private func sendConfiguration(_ configuration: RealtimeTranslationConfiguration) async throws {
        guard let socketTask else { throw RealtimeSessionError.notConnected }

        let noiseReduction = configuration.inputNoiseReduction.map {
            SessionUpdateEvent.Session.Audio.NoiseReduction(type: $0)
        }
        let input: SessionUpdateEvent.Session.Audio.Input?
        if configuration.transcriptionModel != nil || noiseReduction != nil {
            input = .init(
                transcription: configuration.transcriptionModel.map { .init(model: $0) },
                noiseReduction: noiseReduction
            )
        } else {
            input = nil
        }

        let event = SessionUpdateEvent(
            session: .init(audio: .init(input: input, output: .init(language: configuration.targetLanguage)))
        )
        try await send(event, over: socketTask)
    }

    private func send(_ value: some Encodable, over socketTask: URLSessionWebSocketTask) async throws {
        let data = try openAI.encoder.encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw APIError.invalidRequest("Unable to encode realtime translation event as UTF-8")
        }
        try await socketTask.send(.string(json))
    }

    private func receiveLoop() async {
        guard let socketTask else { return }

        do {
            while !Task.isCancelled {
                let message = try await socketTask.receive()
                let data: Data
                switch message {
                    case let .string(string): data = Data(string.utf8)
                    case let .data(payload): data = payload
                    @unknown default: continue
                }
                if let event = decode(from: data) {
                    continuation?.yield(event)
                }
            }
        } catch is CancellationError {
            continuation?.finish()
        } catch {
            continuation?.finish(throwing: error)
        }
    }

    private func decode(from data: Data) -> RealtimeTranslationEvent? {
        guard let envelope = try? openAI.decoder.decode(ServerEnvelope.self, from: data) else {
            if ProcessInfo.processInfo.environment["DEBUG_REALTIME"] != nil {
                let payload = String(data: data, encoding: .utf8) ?? "<binary>"
                NSLog("[DEBUG_REALTIME] Failed to decode translation event payload: %@", payload)
            }
            return nil
        }

        switch envelope.type {
            case "session.created", "session.updated":
                return .sessionConfigured
            case "session.input_transcript.delta":
                return envelope.delta.map(RealtimeTranslationEvent.sourceTranscriptDelta)
            case "session.output_transcript.delta":
                return envelope.delta.map(RealtimeTranslationEvent.translationTranscriptDelta)
            case "session.output_audio.delta":
                guard let base64 = envelope.delta, let pcm = Data(base64Encoded: base64) else { return nil }
                return .audioDelta(pcm)
            case "error":
                return envelope.error.map(RealtimeTranslationEvent.error)
            default:
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return .raw(object.mapValues(JSONValue.init(jsonObject:)))
        }
    }

    private func websocketRequest(apiKey: String) throws -> URLRequest {
        guard var components = URLComponents(url: openAI.endpointURL, resolvingAgainstBaseURL: true) else {
            throw URLError(.badURL)
        }

        components.scheme = components.scheme == "https" ? "wss" : "ws"

        let basePath = openAI.endpointURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathComponents = [basePath, openAI.versionPath, "realtime", "translations"].filter { !$0.isEmpty }
        components.path = "/" + pathComponents.joined(separator: "/")
        components.queryItems = [URLQueryItem(name: "model", value: modelIdentifier)]

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }
}

// MARK: - Wire types (translation namespace)
//
// Property names are camelCase; `OpenAI`'s encoder converts them to the
// snake_case the API expects (e.g. `noiseReduction` -> `noise_reduction`).

private struct SessionUpdateEvent: Encodable {
    let type = "session.update"
    let session: Session

    struct Session: Encodable {
        let audio: Audio

        struct Audio: Encodable {
            let input: Input?
            let output: Output

            struct Input: Encodable {
                let transcription: Transcription?
                let noiseReduction: NoiseReduction?
            }

            struct Output: Encodable { let language: String }
            struct Transcription: Encodable { let model: String }
            struct NoiseReduction: Encodable { let type: String }
        }
    }
}

private struct AudioAppendEvent: Encodable {
    let type = "session.input_audio_buffer.append"
    let audio: String
}

private struct ServerEnvelope: Decodable {
    let type: String
    let delta: String?
    let error: ErrorDetail?
}
