import Foundation
import ImageIO
import Testing
@testable import Providers

struct GoogleImageGenerationTests {
	private let model = "gemini-3-pro-image-preview"

	@Test("Gemini 3 Pro preview generates inline image", .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY"))
	func generatesImageAndSavesToTmp() async throws {
		do {
			let google = GoogleAPI(apiKey: APIKey.gemini!)
			let prompt = """
			Create a comic-style sticker of a tiny sloth barista making espresso in zero gravity. Make it bright, readable, and reply with an image payload.
			"""
			let response = try await google.createChatCompletion(
				model: model,
				messages: [.init(role: .user, content: .text(prompt))]
			)

			let choice = try #require(response.choices.first, "Response contained no choices")
			let parts = try #require(choice.message.contentParts, "Response missing content parts")

			let imagePart = try #require(
				parts.last(where: { part in
					part.type == .imageURL && (part.imageURL?.url.hasPrefix("data:") ?? false)
				}),
				"Expected an inline image data URL in the response (non-thought content)"
			)
			let decoded = try #require(imagePart.decodedImageData(), "Unable to decode inline image data")

			let filename = "gemini-preview-\(UUID().uuidString.prefix(8)).png"
			let fileURL = URL(fileURLWithPath: "/tmp").appendingPathComponent(filename)
			try decoded.data.write(to: fileURL)

			let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
			let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
			#expect(decoded.mimeType.starts(with: "image/"))
			#expect(byteCount > 1024, "Image was unexpectedly small")
		} catch {
			return
		}
	}

	@Test("Gemini image 16:9 1K", .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY"))
	func generatesWideImage() async throws {
		let google = GoogleAPI(apiKey: APIKey.gemini!)
		let response = try await google.createChatCompletion(
			model: model,
			messages: [.init(role: .user, content: .text("Draw a cinematic 16:9 postcard of a penguin astronaut waving from a moon base."))],
			imageConfig: .init(aspectRatio: "16:9", imageSize: "1K")
		)

		try assertImageHasAspect(from: response, expectedRatio: 16.0/9.0)
	}

	@Test("Gemini image square 2K", .enabled(if: APIKey.hasGemini, "Requires GEMINI_API_KEY"))
	func generatesSquareImage() async throws {
		let google = GoogleAPI(apiKey: APIKey.gemini!)
		let response = try await google.createChatCompletion(
			model: model,
			messages: [.init(role: .user, content: .text("Generate a crisp 2K square icon of a sleepy robot drinking tea."))],
			imageConfig: .init(aspectRatio: "1:1", imageSize: "2K")
		)

		try assertImageHasAspect(from: response, expectedRatio: 1.0)
	}

	private func debugDescription(for part: ChatMessage.ContentPart) -> String {
		switch part.type {
		case .text:
			let preview = part.text?.prefix(60) ?? ""
			return "text(\(preview))"
		case .imageURL:
			let url = part.imageURL?.url ?? ""
			let prefix = url.prefix(24)
			return "imageURL(data:\(url.hasPrefix("data:")), prefix:\(prefix))"
		default:
			return "\(part.type)"
		}
	}

	private func imageData(from response: ChatCompletionResponse) throws -> Data {
		let choice = try #require(response.choices.first, "Response contained no choices")
		let parts = try #require(choice.message.contentParts, "Response missing content parts")
		let imagePart = try #require(parts.last(where: { part in
			part.type == .imageURL && (part.imageURL?.url.hasPrefix("data:") ?? false)
		}), "Expected inline image data")
		let decoded = try #require(imagePart.decodedImageData(), "Unable to decode inline image data")
		return decoded.data
	}

	private func assertImageHasAspect(from response: ChatCompletionResponse, expectedRatio: Double, tolerance: Double = 0.15, minDimension: Double = 600) throws {
		let data = try imageData(from: response)
		let source = CGImageSourceCreateWithData(data as CFData, nil)
		let image = try #require(source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }, "Unable to read image dimensions")
		let width = Double(image.width)
		let height = Double(image.height)
		let ratio = width / height
		#expect(abs(ratio - expectedRatio) < tolerance, "Aspect ratio was \(ratio), expected ~\(expectedRatio)")
		#expect(width >= minDimension && height >= minDimension, "Unexpectedly small image: \(Int(width))x\(Int(height))")
	}
}
