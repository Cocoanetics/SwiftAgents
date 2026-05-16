import Foundation
import Providers

/// Logs session events as one JSON line per message to a JSONL file under ~/.coder/sessions/.
struct SessionLogger {
    let sessionId: String
    let filePath: String

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return enc
    }()

    init(model: String, workingDirectory: String) {
        let id = UUID().uuidString.lowercased()
        sessionId = id

        let now = Date()
        let cal = Calendar.current
        let year = String(cal.component(.year, from: now))
        let month = String(format: "%02d", cal.component(.month, from: now))
        let day = String(format: "%02d", cal.component(.day, from: now))

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let timestamp = formatter.string(from: now)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.coder/sessions/\(year)/\(month)/\(day)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        filePath = "\(dir)/session-\(timestamp)-\(id).jsonl"

        log(.sessionStart(SessionStart(sessionId: id, model: model, workingDirectory: workingDirectory)))
    }

    func log(_ entry: SessionEntry) {
        guard let data = try? encoder.encode(entry),
            var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        if let handle = FileHandle(forWritingAtPath: filePath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(toFile: filePath, atomically: false, encoding: .utf8)
        }
    }
}

// MARK: - Entry Types

enum SessionEntry: Encodable {
    case sessionStart(SessionStart)
    case user(UserMessage)
    case toolCall(ToolCallEntry)
    case toolResult(ToolResultEntry)
    case assistant(AssistantMessage)
    case usage(UsageEntry)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
            case let .sessionStart(value):
                try container.encode("session_start", forKey: .type)
                try value.encode(to: encoder)
            case let .user(value):
                try container.encode("user", forKey: .type)
                try value.encode(to: encoder)
            case let .toolCall(value):
                try container.encode("tool_call", forKey: .type)
                try value.encode(to: encoder)
            case let .toolResult(value):
                try container.encode("tool_result", forKey: .type)
                try value.encode(to: encoder)
            case let .assistant(value):
                try container.encode("assistant", forKey: .type)
                try value.encode(to: encoder)
            case let .usage(value):
                try container.encode("usage", forKey: .type)
                try value.encode(to: encoder)
        }
    }
}

struct SessionStart: Encodable {
    let sessionId: String
    let model: String
    let workingDirectory: String
    let timestamp = ISO8601DateFormatter().string(from: Date())
}

struct UserMessage: Encodable {
    let content: String
    let timestamp = ISO8601DateFormatter().string(from: Date())
}

struct ToolCallEntry: Encodable {
    let name: String
    let arguments: String
    let callId: String
    let timestamp = ISO8601DateFormatter().string(from: Date())
}

struct ToolResultEntry: Encodable {
    let callId: String
    let output: String
    let timestamp = ISO8601DateFormatter().string(from: Date())
}

struct AssistantMessage: Encodable {
    let content: String
    let timestamp = ISO8601DateFormatter().string(from: Date())
}

struct UsageEntry: Encodable {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let timestamp = ISO8601DateFormatter().string(from: Date())
}
