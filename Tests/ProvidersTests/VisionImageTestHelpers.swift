import Foundation
import Testing
@testable import Providers

enum VisionImageTestHelpers {
	static func visionFixtureURL() throws -> URL {
		try #require(Bundle.module.url(forResource: "vision-test", withExtension: "png"), "vision-test fixture is required")
	}

	static func visionFixtureData() throws -> Data {
		let url = try visionFixtureURL()
		return try Data(contentsOf: url)
	}

	static func imageOnlyMessage() throws -> ChatMessage {
		let data = try visionFixtureData()
		let textPart = ChatMessage.ContentPart(text: "What is shown in this image?")
		let imagePart = ChatMessage.ContentPart.imageDataPart(mimeType: "image/png", data: data)
		return ChatMessage(role: .user, content: .parts([textPart, imagePart]))
	}

	static func remoteImageMessage(url: String, mimeType: String? = nil) -> ChatMessage {
		let textPart = ChatMessage.ContentPart(text: "What is shown in this online image?")
		let remotePart = ChatMessage.ContentPart(imageURL: url, mimeType: mimeType)
		return ChatMessage(role: .user, content: .parts([textPart, remotePart]))
	}

	static func text(from message: ChatMessage) -> String {
		if let text = message.textContent?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
			return text
		}
		if let parts = message.contentParts,
		   let joined = ChatMessage.ContentPart.joinedText(from: parts)?.trimmingCharacters(in: .whitespacesAndNewlines),
		   !joined.isEmpty {
			return joined
		}
		fatalError("Message has no textual content")
	}

	static func responseInput(prompt: String, attachments: [Response.Input.ContentElement]) -> Response.Input {
		let message = Response.Input.Message(role: "user", content: [.inputText(prompt)] + attachments)
		return .array([.message(message)])
	}

	static func responseText(from response: Response) -> String {
		let sections: [String] = response.output.compactMap { output in
			guard case let .message(message) = output else { return nil }
			let parts = message.content.compactMap { content -> String? in
				if case let .outputText(outputText) = content {
					let trimmed = outputText.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
					return trimmed.isEmpty ? nil : trimmed
				}
				return nil
			}
			guard !parts.isEmpty else { return nil }
			return parts.joined(separator: "\n\n")
		}
		let combined = sections.joined(separator: "\n\n").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
		if combined.isEmpty {
			fatalError("Response has no textual content")
		}
		return combined
	}

	static func responseDataURL(for data: Data, mimeType: String) -> URL {
		let base64 = data.base64EncodedString()
		let string = "data:\(mimeType);base64,\(base64)"
		guard let url = URL(string: string) else {
			fatalError("Unable to create data URL for image input")
		}
		return url
	}
}
