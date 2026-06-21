import Foundation
import Providers

/// Central registry for API providers, keyed by provider name
public actor ProviderRegistry {
    public static let shared = ProviderRegistry()

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
        } else if rawProvider.lowercased() == "openai",
            let loweredName = name?.lowercased(),
                loweredName.contains("claude") {
            // Bare "claude-*" model id without an explicit "anthropic/" prefix.
            "anthropic"
        } else if rawProvider.lowercased() == "gemini" {
            "google"
        } else if rawProvider.lowercased() == "claude" {
            "anthropic"
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

            guard openAI.credential != nil else {
                throw ProviderError.missingAPIKey("OpenAI")
            }

            apis["openai"] = openAI
            return openAI
        }
        // OpenAI Responses over a persistent WebSocket. Addressed as
        // `openai-websocket/<model>` (or `openai-ws/<model>`). This caches a
        // single shared connection — correct for one sequential agent loop, but
        // because a socket is sequential and non-multiplexed, concurrent
        // sessions should each own their own connection: build an
        // `OpenAIResponsesWebSocket()` per session and pass it via
        // `RunConfig.api` instead of routing by name.
        if normalizedProvider.lowercased() == "openai-websocket"
            || normalizedProvider.lowercased() == "openai-ws" {
            if let api = apis[normalizedProvider.lowercased()] {
                return api
            }
            let webSocket = OpenAIResponsesWebSocket()
            guard webSocket.credential != nil else {
                throw ProviderError.missingAPIKey("OpenAI")
            }
            apis[normalizedProvider.lowercased()] = webSocket
            return webSocket
        }
        // Create Google if requested
        if normalizedProvider.lowercased() == "google" {
            let google = GoogleAPI()
            guard google.credential != nil else {
                throw ProviderError.missingAPIKey("Google")
            }
            apis["google"] = google
            return google
        }
        // Create Anthropic if requested
        if normalizedProvider.lowercased() == "anthropic" {
            let anthropic = Anthropic()
            guard anthropic.credential != nil else {
                throw ProviderError.missingAPIKey("Anthropic")
            }
            apis["anthropic"] = anthropic
            return anthropic
        }
        // Create Ollama if requested (local LLM)
        if normalizedProvider.lowercased() == "local" || normalizedProvider.lowercased() == "ollama" {
            let baseURL = ProcessInfo.processInfo.environment["OLLAMA_URL"] ?? "http://localhost:11434"
            let ollama = OllamaAPI(endpointURL: URL(string: baseURL)!, versionPath: "v1")
            apis[normalizedProvider.lowercased()] = ollama
            return ollama
        }
        // Create LM Studio if requested. Talks to LM Studio's native stateful
        // chat endpoint (`/api/v1/chat`) so the Runner can chain turns via
        // `previous_response_id` instead of resending history.
        if normalizedProvider.lowercased() == "lmstudio" {
            let baseURL = ProcessInfo.processInfo.environment["LMSTUDIO_URL"] ?? "http://localhost:1234"
            let lmstudio = LMStudio(endpointURL: URL(string: baseURL)!)
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
