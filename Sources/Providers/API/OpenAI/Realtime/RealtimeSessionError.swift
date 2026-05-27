import Foundation

public enum RealtimeSessionError: LocalizedError {
    case alreadyConnected
    case notConnected
    case modelChangeRequiresNewSession(current: String, requested: String)

    public var errorDescription: String? {
        switch self {
            case .alreadyConnected:
                return "Realtime session is already connected"
            case .notConnected:
                return "Realtime session is not connected"
            case let .modelChangeRequiresNewSession(current, requested):
                return """
                Realtime sessions cannot change model from \(current) to \(requested) \
                after the WebSocket has connected. Start a new session instead.
                """
        }
    }
}
