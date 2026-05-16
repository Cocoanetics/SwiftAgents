import Foundation

/// Central registry for API providers, keyed by provider name
public actor Providers {
    public static let shared = Providers()

    private var apis: [String: API] = [:]

    /// Returns the API instance for a given model name or provider name.
    /// - Parameter name: e.g. "local/llama3", "openai/gpt-4o", or just "gpt-4o" or nil
    /// - Throws: ProviderError if the provider is unknown or misconfigured
    public func api(for name: String?) async throws -> API {
        // Determine provider name
        let rawProvider = if let name, let slashIdx = name.firstIndex(of: "/") {
            String(name[..<slashIdx])
        } else {
            "openai"
        }

        let normalizedProvider: String = if rawProvider.lowercased() == "openai",
            let loweredName = name?.lowercased(),
                loweredName.contains("gemini") {
            "google"
        } else if rawProvider.lowercased() == "gemini" {
            "google"
        } else {
            rawProvider
        }

        // Check cache
        if let api = apis[normalizedProvider] {
            return api
        }
        // Create and register OpenAI if needed
        if normalizedProvider.lowercased() == "openai" {
            let openAI = OpenAI()

            guard openAI.apiKey != nil else {
                throw ProviderError.missingAPIKey("OpenAI")
            }

            apis["openai"] = openAI
            return openAI
        }
        // Create Google if requested
        if normalizedProvider.lowercased() == "google" {
            let google = GoogleAPI()
            guard google.apiKey != nil else {
                throw ProviderError.missingAPIKey("Google")
            }
            apis["google"] = google
            return google
        }
        // Create Ollama if requested (local LLM)
        if normalizedProvider.lowercased() == "local" || normalizedProvider.lowercased() == "ollama" {
            let baseURL = ProcessInfo.processInfo.environment["OLLAMA_URL"] ?? "http://localhost:11434"
            let ollama = OllamaAPI(endpointURL: URL(string: baseURL)!, versionPath: "v1")
            apis[normalizedProvider.lowercased()] = ollama
            return ollama
        }
        // Create LM Studio if requested (OpenAI-compatible local LLM)
        if normalizedProvider.lowercased() == "lmstudio" {
            let baseURL = ProcessInfo.processInfo.environment["LMSTUDIO_URL"] ?? "http://192.168.1.142:1234"
            let lmstudio = OpenAI(apiKey: "lm-studio", endpointURL: URL(string: baseURL)!, versionPath: "v1")
            apis["lmstudio"] = lmstudio
            return lmstudio
        }
        // Unknown provider
        throw ProviderError.unknownProvider(normalizedProvider)
    }

    /// Registers a custom API instance for a provider name
    public func register(api: API, forProvider provider: String) async {
        apis[provider] = api
    }
}
