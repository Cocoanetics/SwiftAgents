import Foundation

struct ShowFileContent: Identifiable {
    let id = UUID()
    let title: String
    let content: String
}

enum TranscriptRole: String, Sendable {
    case user
    case assistant
    case tool
    case system

    var title: String {
        switch self {
        case .user:
            return "You"
        case .assistant:
            return "Assistant"
        case .tool:
            return "Tool"
        case .system:
            return "System"
        }
    }
}

struct TranscriptEntry: Identifiable, Equatable, Sendable {
    let id: String
    var sourceItemIDs: [String]
    let role: TranscriptRole
    var text: String
    var fullOutput: String?
    var isFinal: Bool
    var updatedAt: Date
}
