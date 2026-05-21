import Foundation

enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case disconnecting
    case disconnected
    case failed(String)

    var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .disconnecting:
            return "Disconnecting"
        case .disconnected:
            return "Disconnected"
        case .failed:
            return "Failed"
        }
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .disconnecting:
            return true
        default:
            return false
        }
    }

    var isLive: Bool {
        self == .connected
    }
}
