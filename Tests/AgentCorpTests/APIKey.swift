import Foundation
import SwiftDotenv

enum APIKey {
	private static let envLoaded: Void = {
		guard let envURL = findEnvFile() else { return }
		try? Dotenv.configure(atPath: envURL.path)
	}()

	private static func findEnvFile() -> URL? {
		let candidates = [".env.development", ".env"]
		var current = URL(fileURLWithPath: #file).deletingLastPathComponent()
		let fileManager = FileManager.default
		while true {
			for name in candidates {
				let candidate = current.appendingPathComponent(name)
				if fileManager.fileExists(atPath: candidate.path) {
					return candidate
				}
			}
			let parent = current.deletingLastPathComponent()
			if parent.path == current.path { break }
			current = parent
		}
		return nil
	}

	private static func loadEnvIfNeeded() {
		_ = envLoaded
	}

	static var openAI: String? {
		loadEnvIfNeeded()
		return ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
	}
	
	static var gemini: String? {
		loadEnvIfNeeded()
		return ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
	}
	
	static var hasOpenAI: Bool { openAI != nil }
	static var hasGemini: Bool { gemini != nil }
}
