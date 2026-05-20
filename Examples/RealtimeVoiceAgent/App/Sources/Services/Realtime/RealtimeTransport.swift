import Foundation
import SwiftMCP

actor RealtimeTransport {
    enum TransportError: LocalizedError {
        case notConnected
        case invalidMessage

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "The realtime socket is not connected."
            case .invalidMessage:
                return "Received an unsupported realtime message."
            }
        }
    }

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?

    func connect(url: URL, headers: [String: String]) {
        disconnect()

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true

        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        socket.resume()
    }

    func send(_ event: JSONValue) async throws {
        guard let socket else {
            throw TransportError.notConnected
        }

        let data = try JSONEncoder().encode(event)
        try await socket.send(.string(String(data: data, encoding: .utf8)!))
    }

    func receive() async throws -> JSONValue {
        guard let socket else {
            throw TransportError.notConnected
        }

        let message = try await socket.receive()

        switch message {
        case .string(let string):
            return try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
        case .data(let data):
            guard let string = String(data: data, encoding: .utf8) else {
                throw TransportError.invalidMessage
            }
            return try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
        @unknown default:
            throw TransportError.invalidMessage
        }
    }

    func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        socket = nil
        session = nil
    }
}
