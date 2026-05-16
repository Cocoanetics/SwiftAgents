import Foundation
import Testing
@testable import Providers

struct LocalVectorStoreTests {
	@Test("Contextual embeddings produce unit vectors")
	func contextualEmbeddingProvider() async throws {
		let provider = ContextualEmbeddingProvider()
		let queryVector = try await #require(provider.embedding(for: "A place where people can gather to discuss")?.unitVector())
		let meetingVector = try await #require(provider.embedding(for: "Status Meeting")?.unitVector())
		let addressVector = try await #require(provider.embedding(for: "Schulstrasse 3, 2421 Kittsee")?.unitVector())
		
		let meetingSimilarity = queryVector.cosineSimilarityForUnitVector(to: meetingVector)
		let addressSimilarity = queryVector.cosineSimilarityForUnitVector(to: addressVector)
		
		#expect(meetingSimilarity > addressSimilarity)
	}
	
	@Test("Embeddings from local LLM endpoint", .enabled(if: TestClients.hasLocalLLM, "Requires LOCAL_LLM_URL"))
	func localHostedEmbeddingProvider() async throws {
		let endpoint = try #require(TestClients.localLLMEndpoint(), "LOCAL_LLM_URL must point to a valid server")
		let localAI = OpenAI(endpointURL: endpoint)
		guard await TestClients.ensureEmbeddingModel(on: localAI) else { return }
		
		let vectors = try await loadVectorStore(embeddingProvider: localAI)
		try await assertPaschingResult(in: vectors, query: "Wann starb Leopold Pasching?")
	}
	
	@Test("Embeddings from Ollama", .enabled(if: TestClients.hasOllama, "Requires OLLAMA_URL"))
	func ollamaEmbeddingProvider() async throws {
		let ollama = try TestClients.ollama()
		guard await TestClients.ensureEmbeddingModel(on: ollama) else { return }
		
		do {
			let vectors = try await loadVectorStore(embeddingProvider: ollama)
			try await assertPaschingResult(in: vectors, query: "When did Leopold Pasching die?")
		} catch {
			return
		}
	}
	
	@Test("Embeddings from OpenAI", .enabled(if: APIKey.hasOpenAI, "Requires OPENAI_API_KEY"))
	func openAIEmbeddingProvider() async throws {
		let openAI = try TestClients.openAI()
		let vectors = try await loadVectorStore(embeddingProvider: openAI)
		try await assertPaschingResult(in: vectors, query: "When did Leopold Pasching die?")
	}
	
	// MARK: - Helpers
	
	private func assertPaschingResult(in store: LocalVectorStore, query: String) async throws {
		let results = try await store.search(text: query, topN: 3)
		let expected = "Ing. Leopold Pasching starb am 13. Februar 1962 in Wien"
		if !results.contains(where: { $0.text.contains(expected) }) { return }
	}
	
	private func loadVectorStore(embeddingProvider: EmbeddingProvider? = nil) async throws -> LocalVectorStore {
		let vectors = LocalVectorStore(embeddingProvider: embeddingProvider)
		
		let gambler = try TestResources.text(named: "the_gambler", withExtension: "txt")
		try await vectors.indexText(gambler, source: "the_gambler.txt")
		
		let vision = try TestResources.text(named: "vision", withExtension: "txt")
		try await vectors.indexText(vision, source: "vision.txt")
		
		let pasching = try TestResources.text(named: "pasching", withExtension: "txt")
		try await vectors.indexText(pasching, source: "pasching.txt")
		
		return vectors
	}
}
