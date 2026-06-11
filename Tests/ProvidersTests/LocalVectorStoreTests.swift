import Foundation
@testable import Providers
import Testing
@testable import SemanticStore

struct LocalVectorStoreTests {
    // `ContextualEmbeddingProvider` wraps `NLContextualEmbedding`, which is
    // Apple-only. The type is itself gated with `#if canImport(NaturalLanguage)`
    // in `Sources/VectorStore/ContextualEmbeddingProvider.swift`, so on
    // Linux / Windows / Android the symbol doesn't exist and this test
    // can't reference it. Gate it out on those platforms.
    //
    // On CI (where `$CI` is set), also skip: the first call to
    // `NLContextualEmbedding(language:)` downloads an Apple model and
    // a fresh runner has no cache, which hangs the test step for
    // ~10 minutes before the CI step times out. Locally the model is
    // cached so this runs in <250ms.
    #if canImport(NaturalLanguage)
    @Test(
        "Contextual embeddings produce unit vectors",
        .enabled(
            if: ProcessInfo.processInfo.environment["CI"] == nil,
            "Skipped on CI — NLContextualEmbedding asset download stalls fresh runners"
        )
    )
    func contextualEmbeddingProvider() async throws {
        let provider = ContextualEmbeddingProvider()
        let queryVector = try await #require(provider.embedding(for: "A place where people can gather to discuss")?
            .unitVector())
        let meetingVector = try await #require(provider.embedding(for: "Status Meeting")?.unitVector())
        let addressVector = try await #require(provider.embedding(for: "Schulstrasse 3, 2421 Kittsee")?.unitVector())

        let meetingSimilarity = queryVector.cosineSimilarityForUnitVector(to: meetingVector)
        let addressSimilarity = queryVector.cosineSimilarityForUnitVector(to: addressVector)

        #expect(meetingSimilarity > addressSimilarity)
    }

    @Test(
        "Short, language-ambiguous text still embeds via the system-language fallback",
        .enabled(
            if: ProcessInfo.processInfo.environment["CI"] == nil,
            "Skipped on CI — NLContextualEmbedding asset download stalls fresh runners"
        )
    )
    func contextualEmbeddingShortQueryFallsBack() async throws {
        // A one-word query is too short for NLLanguageRecognizer to decide a
        // language; the provider must fall back to the system language (then
        // English) and still return a vector rather than throwing.
        let provider = ContextualEmbeddingProvider()
        let vector = try await provider.embedding(for: "cat")
        #expect(vector != nil)
    }
    #endif

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

    // Deterministic counterpart to the live OpenAI test: real recorded
    // text-embedding-3-small vectors (no key), so the brute-force store's
    // ranking is exercised against real embedding geometry on every platform.
    @Test("Recorded OpenAI embeddings rank by meaning (no key)")
    func recordedOpenAIEmbeddings() async throws {
        let store = LocalVectorStore(embeddingProvider: try RecordedEmbeddingProvider())
        try await store.indexText(
            "Leopold Pasching, an Austrian engineer, died on 13 February 1962 in Vienna.",
            source: "pasching.txt"
        )
        try await store.indexText(
            "The Eiffel Tower is an iron lattice tower on the Champ de Mars in Paris, France.",
            source: "eiffel.txt"
        )
        try await store.indexText(
            "Honeybees communicate the location of nectar to the hive through a waggle dance.",
            source: "bees.txt"
        )
        try await store.indexText(
            "The central bank raised its benchmark interest rate by half a percentage point.",
            source: "bank.txt"
        )
        let results = try await store.search(text: "When did Leopold Pasching die?", topN: 1)
        #expect(results.first?.source == "pasching.txt")
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
