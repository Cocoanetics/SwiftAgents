import Foundation
@testable import Providers
import Testing

enum TestClients {
    static var hasOllama: Bool {
        ProcessInfo.processInfo.environment["OLLAMA_URL"] != nil
    }

    static var hasLocalLLM: Bool {
        ProcessInfo.processInfo.environment["LOCAL_LLM_URL"] != nil
    }

    static var hasLMStudio: Bool {
        ProcessInfo.processInfo.environment["LMSTUDIO_URL"] != nil
    }

    static func lmStudio() throws -> LMStudio {
        let raw = try #require(
            ProcessInfo.processInfo.environment["LMSTUDIO_URL"],
            "LMSTUDIO_URL is required for this test"
        )
        let urlString = raw.hasPrefix("http") ? raw : "http://" + raw
        let endpoint = try #require(URL(string: urlString), "LMSTUDIO_URL must be a valid URL")
        return LMStudio(endpointURL: endpoint)
    }

    private static let embeddingDetector = EmbeddingDetector()

    static func openAI() throws -> OpenAI {
        let key = try #require(APIKey.openAI, "OPENAI_API_KEY is required for this test")
        return OpenAI(apiKey: key)
    }

    static func google() throws -> GoogleAPI {
        let key = try #require(APIKey.gemini, "GEMINI_API_KEY is required for this test")
        return GoogleAPI(apiKey: key)
    }

    static func anthropic() throws -> Anthropic {
        let key = try #require(APIKey.anthropic, "ANTHROPIC_API_KEY is required for this test")
        return Anthropic(apiKey: key)
    }

    static func ollama() throws -> OllamaAPI {
        let raw = try #require(
            ProcessInfo.processInfo.environment["OLLAMA_URL"],
            "OLLAMA_URL is required for this test"
        )
        let urlString = raw.hasPrefix("http") ? raw : "http://" + raw
        let endpoint = try #require(URL(string: urlString), "OLLAMA_URL must be a valid URL")
        return OllamaAPI(endpointURL: endpoint)
    }

    static func localLLMEndpoint() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["LOCAL_LLM_URL"] else {
            return nil
        }
        let urlString = raw.hasPrefix("http") ? raw : "http://" + raw
        return URL(string: urlString)
    }

    static func ensureEmbeddingModel(on api: some API & EmbeddingProvider) async -> Bool {
        await embeddingDetector.ensureEmbeddingModel(on: api)
    }

    static var hasLocalEmbeddingModel: Bool {
        get async {
            guard let endpoint = localLLMEndpoint() else { return false }
            let api = OpenAI(endpointURL: endpoint)
            return await ensureEmbeddingModel(on: api)
        }
    }

    static var hasOllamaEmbeddingModel: Bool {
        get async {
            guard hasOllama, let api = try? ollama() else { return false }
            return await ensureEmbeddingModel(on: api)
        }
    }
}

private actor EmbeddingDetector {
    private var cachedModelIdentifiers: [URL: String] = [:]

    func ensureEmbeddingModel(on api: some API & EmbeddingProvider) async -> Bool {
        let endpoint = api.endpointURL
        if let identifier = cachedModelIdentifiers[endpoint] {
            api.embeddingModelIdentifier = identifier
            return true
        }

        guard let models = try? await api.models(),
            let embedModel = models.first(where: { $0.id.contains("embed") }) else {
            return false
        }

        cachedModelIdentifiers[endpoint] = embedModel.id
        api.embeddingModelIdentifier = embedModel.id
        return true
    }
}
