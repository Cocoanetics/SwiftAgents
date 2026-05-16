import Foundation
import Testing
@testable import AgentCorp

struct VectorStoreFileTests {
	@Test("Vector store file reaches completed status", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
	func attachesFile() async throws {
		let openAI = try TestClients.openAI()
		let fixture = try TestResources.url(forResource: "pasching", withExtension: "txt")
		let file = try await openAI.uploadFile(url: fixture, filename: "file-\(UUID().uuidString.prefix(6)).txt", purpose: .assistants)
		let store = try await openAI.createVectorStore(name: "FileStore \(UUID().uuidString.prefix(6))", metadata: ["scope": "swift-testing"])

		let storeFile = try await openAI.createVectorStoreFile(vectorStoreId: store.id, fileId: file.id)
		#expect(storeFile.vectorStoreId == store.id)
		#expect(storeFile.id == file.id)
		
		let readyFile = try await openAI.waitUntilVectorStoreFileIsReady(vectorStoreId: store.id, fileId: file.id)
		#expect(readyFile.status == .completed)
		
		let deletedStoreFile = try await openAI.deleteVectorStoreFile(vectorStoreId: store.id, fileId: file.id)
		#expect(deletedStoreFile)
		
		_ = try? await openAI.deleteFile(id: file.id)
		_ = try? await openAI.deleteVectorStore(id: store.id)
	}
}
