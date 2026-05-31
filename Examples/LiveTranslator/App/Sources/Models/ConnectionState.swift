import Foundation

enum ConnectionState: Equatable {
    case idle
    case starting
    case listening
    case stopping
    case failed(String)

    var title: String {
        switch self {
            case .idle:
                return "Ready"
            case .starting:
                return "Connecting"
            case .listening:
                return "Listening"
            case .stopping:
                return "Stopping"
            case .failed:
                return "Failed"
        }
    }

    var isBusy: Bool {
        switch self {
            case .starting, .stopping: return true
            default: return false
        }
    }

    var isLive: Bool {
        self == .listening
    }
}
