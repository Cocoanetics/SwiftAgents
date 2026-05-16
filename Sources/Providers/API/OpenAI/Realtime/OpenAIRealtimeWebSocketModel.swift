import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftMCP

public actor OpenAIRealtimeWebSocketModel: RealtimeModel {
    private let openAI: OpenAI
    private let session: URLSession
    private let modelIdentifier: String

    private var socketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<RealtimeServerEvent, Error>.Continuation?
    private var stream: AsyncThrowingStream<RealtimeServerEvent, Error>?

    public init(
        openAI: OpenAI = OpenAI(),
        model: String = "gpt-realtime",
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

    public func connect() async throws -> AsyncThrowingStream<RealtimeServerEvent, Error> {
        if let stream {
            return stream
        }

        guard let apiKey = openAI.apiKey, !apiKey.isEmpty else {
            throw APIError.authenticationError("OPENAI_API_KEY is required for realtime sessions")
        }

        let request = try websocketRequest(apiKey: apiKey)
        let socketTask = session.webSocketTask(with: request)
        let (stream, continuation) = AsyncThrowingStream<RealtimeServerEvent, Error>.makeStream()

        self.socketTask = socketTask
        self.stream = stream
        self.continuation = continuation

        socketTask.resume()

        receiveTask = Task {
            await receiveLoop()
        }

        return stream
    }

    public func send(_ event: some Encodable & Sendable) async throws {
        guard let socketTask else {
            throw RealtimeSessionError.notConnected
        }

        let data = try openAI.encoder.encode(event)
        guard let message = String(data: data, encoding: .utf8) else {
            throw APIError.invalidRequest("Unable to encode realtime event as UTF-8")
        }

        try await socketTask.send(.string(message))
    }

    public func sendRaw(_ payload: [String: JSONValue]) async throws {
        guard let socketTask else {
            throw RealtimeSessionError.notConnected
        }

        let data = try openAI.encoder.encode(payload)
        guard let message = String(data: data, encoding: .utf8) else {
            throw APIError.invalidRequest("Unable to encode realtime payload as UTF-8")
        }

        try await socketTask.send(.string(message))
    }

    public func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil

        if let socketTask {
            socketTask.cancel(with: .normalClosure, reason: nil)
        }

        socketTask = nil

        if let continuation {
            continuation.finish()
        }

        continuation = nil
        stream = nil
    }

    private func receiveLoop() async {
        guard let socketTask else {
            return
        }

        do {
            while !Task.isCancelled {
                let message = try await socketTask.receive()
                let data: Data

                switch message {
                    case let .string(string):
                        data = Data(string.utf8)
                    case let .data(payload):
                        data = payload
                    @unknown default:
                        continue
                }

                do {
                    let event = try RealtimeServerEvent.decode(from: data, decoder: openAI.decoder)
                    continuation?.yield(event)
                } catch {
                    if ProcessInfo.processInfo.environment["DEBUG_REALTIME"] != nil {
                        let payload = String(data: data, encoding: .utf8) ?? "<binary>"
                        NSLog("[DEBUG_REALTIME] Failed to decode realtime event payload: %@", payload)
                    }
                    throw error
                }
            }
        } catch is CancellationError {
            continuation?.finish()
        } catch {
            continuation?.finish(throwing: error)
        }
    }

    private func websocketRequest(apiKey: String) throws -> URLRequest {
        guard var components = URLComponents(url: openAI.endpointURL, resolvingAgainstBaseURL: true) else {
            throw URLError(.badURL)
        }

        components.scheme = components.scheme == "https" ? "wss" : "ws"

        let basePath = openAI.endpointURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathComponents = [basePath, openAI.versionPath, "realtime"].filter { !$0.isEmpty }
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
