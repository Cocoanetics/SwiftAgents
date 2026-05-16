import Foundation
import Testing
@testable import Providers

struct FilesTests {
	@Test("File upload and delete", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
	func fileLifecycle() async throws {
		let openAI = try TestClients.openAI()
		let fixture = try TestResources.url(forResource: "pasching", withExtension: "txt")
		let filename = "test-\(UUID().uuidString.prefix(8)).txt"

		let file = try await openAI.uploadFile(url: fixture, filename: filename, purpose: .userData)
		#expect(!file.id.isEmpty)

		let files = try await openAI.listFiles()
		#expect(files.contains { $0.id == file.id })

		let retrieved = try await openAI.retrieveFile(id: file.id)
		#expect(retrieved.id == file.id)

		let deleted = try await openAI.deleteFile(id: file.id)
		#expect(deleted)
	}
}
