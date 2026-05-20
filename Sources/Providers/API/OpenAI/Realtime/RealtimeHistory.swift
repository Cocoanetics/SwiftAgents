import Foundation

public actor RealtimeHistory {
    public enum Change: Sendable {
        case inserted(RealtimeConversationItem)
        case updated(RealtimeConversationItem)
        case deleted(String)
    }

    private var orderedItemIDs = [String]()
    private var itemsByID = [String: RealtimeConversationItem]()

    public init() {}

    public func upsert(_ item: RealtimeConversationItem, previousItemID: String? = nil) -> Change? {
        guard let itemID = item.id else {
            return nil
        }

        let change: Change
        if itemsByID[itemID] == nil {
            insert(itemID: itemID, after: previousItemID)
            change = .inserted(item)
        } else {
            change = .updated(item)
        }

        itemsByID[itemID] = item
        return change
    }

    public func delete(itemID: String) -> Change? {
        guard itemsByID.removeValue(forKey: itemID) != nil else {
            return nil
        }

        orderedItemIDs.removeAll { $0 == itemID }
        return .deleted(itemID)
    }

    public func applyTruncation(itemID: String, contentIndex: Int, audioEndMilliseconds: Int) -> Change? {
        guard var item = itemsByID[itemID] else {
            return nil
        }

        guard item.markAudioTruncated(contentIndex: contentIndex, audioEndMilliseconds: audioEndMilliseconds) else {
            return nil
        }

        itemsByID[itemID] = item
        return .updated(item)
    }

    public func applyInputAudioTranscript(itemID: String, contentIndex: Int, transcript: String) -> Change? {
        guard var item = itemsByID[itemID] else {
            return nil
        }

        guard item.updateTranscript(contentIndex: contentIndex, transcript: transcript) else {
            return nil
        }

        itemsByID[itemID] = item
        return .updated(item)
    }

    public func snapshot() -> [RealtimeConversationItem] {
        orderedItemIDs.compactMap { itemsByID[$0] }
    }

    /// Writes the given items to `url` as a JSON array. Symmetric with `load(from:)`.
    public static func save(_ items: [RealtimeConversationItem], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(items)
        try data.write(to: url, options: .atomic)
    }

    /// Reads items previously written by `save(_:to:)`. Returns `[]` if the file
    /// doesn't exist; throws on a corrupt payload.
    public static func load(from url: URL) throws -> [RealtimeConversationItem] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([RealtimeConversationItem].self, from: data)
    }

    private func insert(itemID: String, after previousItemID: String?) {
        guard !orderedItemIDs.contains(itemID) else {
            return
        }

        if let previousItemID, let previousIndex = orderedItemIDs.firstIndex(of: previousItemID) {
            orderedItemIDs.insert(itemID, at: previousIndex + 1)
        } else {
            orderedItemIDs.append(itemID)
        }
    }
}

private extension RealtimeConversationItem {
    mutating func updateTranscript(contentIndex: Int, transcript: String) -> Bool {
        guard case var .message(message) = self else {
            return false
        }

        guard message.updateTranscript(contentIndex: contentIndex, transcript: transcript) else {
            return false
        }

        self = .message(message)
        return true
    }

    mutating func markAudioTruncated(contentIndex: Int, audioEndMilliseconds: Int) -> Bool {
        guard case var .message(message) = self else {
            return false
        }

        guard message.markAudioTruncated(contentIndex: contentIndex, audioEndMilliseconds: audioEndMilliseconds) else {
            return false
        }

        self = .message(message)
        return true
    }
}

private extension RealtimeConversationItem.Message {
    mutating func updateTranscript(contentIndex: Int, transcript: String) -> Bool {
        guard content.indices.contains(contentIndex) else {
            return false
        }

        switch content[contentIndex] {
            case var .inputAudio(audio):
                audio.transcript = transcript
                content[contentIndex] = .inputAudio(audio)
                return true
            case var .outputAudio(audio):
                audio.transcript = transcript
                content[contentIndex] = .outputAudio(audio)
                return true
            case .inputText, .outputText:
                return false
        }
    }

    mutating func markAudioTruncated(contentIndex: Int, audioEndMilliseconds: Int) -> Bool {
        guard content.indices.contains(contentIndex) else {
            return false
        }

        switch content[contentIndex] {
            case var .outputAudio(audio):
                audio.audioEndMilliseconds = audioEndMilliseconds
                content[contentIndex] = .outputAudio(audio)
                return true
            case .inputAudio, .inputText, .outputText:
                return false
        }
    }
}
