import Foundation

public actor RealtimeHistory {
	public enum Change: Sendable {
		case inserted(RealtimeConversationItem)
		case updated(RealtimeConversationItem)
		case deleted(String)
	}

	private var orderedItemIDs = [String]()
	private var itemsByID = [String: RealtimeConversationItem]()

	public init() {
	}

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
		guard case .message(var message) = self else {
			return false
		}

		guard message.updateTranscript(contentIndex: contentIndex, transcript: transcript) else {
			return false
		}

		self = .message(message)
		return true
	}

	mutating func markAudioTruncated(contentIndex: Int, audioEndMilliseconds: Int) -> Bool {
		guard case .message(var message) = self else {
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
			case .inputAudio(var audio):
				audio.transcript = transcript
				content[contentIndex] = .inputAudio(audio)
				return true
			case .outputAudio(var audio):
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
			case .outputAudio(var audio):
				audio.audioEndMilliseconds = audioEndMilliseconds
				content[contentIndex] = .outputAudio(audio)
				return true
			case .inputAudio, .inputText, .outputText:
				return false
		}
	}
}
