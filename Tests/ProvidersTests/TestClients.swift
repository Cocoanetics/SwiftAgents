import Foundation
@testable import Providers
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum TestClients {
    /// Reads a process-environment variable after ensuring SwiftDotenv
    /// has had a chance to load the nearest `.env` file. Mirrors how
    /// `APIKey` reads `OPENAI_API_KEY` etc. — without this hop, the
    /// local-LLM gates below evaluate before `.env` is loaded if no
    /// `APIKey.*` accessor has been touched yet (e.g. when filtering
    /// `swift test --filter "LMStudio"`), and the entire suite silently
    /// skips even though the value is sitting in `.env`.
    private static func env(_ name: String) -> String? {
        APIKey.loadEnvIfNeeded()
        return ProcessInfo.processInfo.environment[name]
    }

    static var hasOllama: Bool {
        env("OLLAMA_URL") != nil
    }

    static var hasLocalLLM: Bool {
        env("LOCAL_LLM_URL") != nil
    }

    static var hasLMStudio: Bool {
        env("LMSTUDIO_URL") != nil
    }

    /// `RUN_OLLAMA_TESTS=1` opt-in for the live Ollama chat suites. Read
    /// through `env(_:)` so a value declared only in `.env` counts too —
    /// a raw `ProcessInfo` read in a `static let` evaluates before the
    /// `.env` load and silently skips the suite.
    static var runsOllamaTests: Bool {
        env("RUN_OLLAMA_TESTS") != nil
    }

    /// Second-tier opt-in for live OpenAI suites that create, mutate, or
    /// poll *hosted* server-side state (vector stores, conversations,
    /// assistants, files, session resume). Key presence alone enables the
    /// cheap inference tests; these suites additionally flake on
    /// server-side ingestion/convergence timing, so they want an explicit
    /// `LIVE_STATE_TESTS=1` next to `OPENAI_API_KEY`.
    static var runsHostedStateTests: Bool {
        APIKey.hasOpenAI && env("LIVE_STATE_TESTS") != nil
    }

    // MARK: - Local-server reachability

    private static let reachabilityDetector = ReachabilityDetector()

    /// True when `LMSTUDIO_URL` is set *and* something is answering there.
    /// Probed once per process (cached, 2 s timeout) so a configured-but-dead
    /// server turns the LM Studio suites into skips instead of ~16
    /// connection-refused failures.
    static var lmStudioReachable: Bool {
        get async { await reachable("LMSTUDIO_URL") }
    }

    /// True when `OLLAMA_URL` is set and something is answering there.
    static var ollamaReachable: Bool {
        get async { await reachable("OLLAMA_URL") }
    }

    /// True when `LOCAL_LLM_URL` is set and something is answering there.
    static var localLLMReachable: Bool {
        get async { await reachable("LOCAL_LLM_URL") }
    }

    private static func reachable(_ name: String) async -> Bool {
        guard let raw = env(name), let endpoint = normalizedURL(from: raw) else {
            return false
        }
        return await reachabilityDetector.isReachable(endpoint)
    }

    // MARK: - Clients

    /// The LM Studio endpoint from `LMSTUDIO_URL`, with the same
    /// `http://`-prefix normalization `lmStudio()` applies — extracted so
    /// tests that build their own client (e.g. the recording subclass in
    /// `LMStudioResponsesRoutingLiveTests`) share it instead of re-reading
    /// the raw environment variable.
    static func lmStudioURL() throws -> URL {
        let raw = try #require(
            env("LMSTUDIO_URL"),
            "LMSTUDIO_URL is required for this test"
        )
        return try #require(normalizedURL(from: raw), "LMSTUDIO_URL must be a valid URL")
    }

    static func lmStudio() throws -> LMStudio {
        LMStudio(endpointURL: try lmStudioURL())
    }

    private static let embeddingDetector = EmbeddingDetector()

    static func openAI() throws -> OpenAI {
        let key = try #require(APIKey.openAI, "OPENAI_API_KEY is required for this test")
        return OpenAI(credential: Credential.bearer(key))
    }

    static func google() throws -> GoogleAPI {
        let key = try #require(APIKey.gemini, "GEMINI_API_KEY is required for this test")
        return GoogleAPI(credential: Credential.googleAPIKey(key))
    }

    static func anthropic() throws -> Anthropic {
        let key = try #require(APIKey.anthropic, "ANTHROPIC_API_KEY is required for this test")
        return Anthropic(credential: Credential.apiKey(key))
    }

    static func ollama() throws -> OllamaAPI {
        let raw = try #require(
            env("OLLAMA_URL"),
            "OLLAMA_URL is required for this test"
        )
        let endpoint = try #require(normalizedURL(from: raw), "OLLAMA_URL must be a valid URL")
        return OllamaAPI(endpointURL: endpoint)
    }

    static func localLLMEndpoint() -> URL? {
        guard let raw = env("LOCAL_LLM_URL") else {
            return nil
        }
        return normalizedURL(from: raw)
    }

    /// The `http://`-prefix normalization every local-server URL shares —
    /// `LMSTUDIO_URL=localhost:1234` works the same as a full URL.
    private static func normalizedURL(from raw: String) -> URL? {
        URL(string: raw.hasPrefix("http") ? raw : "http://" + raw)
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

/// Shared `ConditionTrait`s for the live suites, so every gate is built
/// from a `TestClients`/`APIKey` accessor in this one file — greppable,
/// `.env`-consistent, and upgradable (e.g. to reachability probes)
/// without touching the suites.
enum LiveGate {
    /// Live OpenAI suites that create/mutate/poll hosted server-side
    /// state. Opt-in beyond key presence — see
    /// `TestClients.runsHostedStateTests`.
    static let openAIState = ConditionTrait.enabled(
        if: TestClients.runsHostedStateTests,
        "Requires OPENAI_API_KEY and LIVE_STATE_TESTS=1 (mutates hosted state; flaky on server-side convergence)"
    )

    /// LM Studio live suites: skip (rather than fail with
    /// connection-refused) unless something is answering at LMSTUDIO_URL.
    static let lmStudio = ConditionTrait.enabled(
        "Requires a reachable LM Studio at LMSTUDIO_URL"
    ) { await TestClients.lmStudioReachable }

    /// LM Studio plus an OpenAI key (trace-ingest round trips).
    static let lmStudioAndOpenAI = ConditionTrait.enabled(
        "Requires OPENAI_API_KEY and a reachable LM Studio at LMSTUDIO_URL"
    ) {
        guard APIKey.hasOpenAI else { return false }
        return await TestClients.lmStudioReachable
    }

    /// Ollama chat suites: explicit opt-in plus a reachable server.
    static let ollama = ConditionTrait.enabled(
        "Requires RUN_OLLAMA_TESTS=1 and a reachable Ollama at OLLAMA_URL"
    ) {
        guard TestClients.runsOllamaTests else { return false }
        return await TestClients.ollamaReachable
    }

    /// Ollama embedding tests — no opt-in var, just a live server.
    static let ollamaReachable = ConditionTrait.enabled(
        "Requires a reachable Ollama at OLLAMA_URL"
    ) { await TestClients.ollamaReachable }

    /// A generic OpenAI-compat local server via LOCAL_LLM_URL.
    static let localLLM = ConditionTrait.enabled(
        "Requires a reachable local LLM at LOCAL_LLM_URL"
    ) { await TestClients.localLLMReachable }
}

/// One-shot per-URL reachability probe shared by the local-server gates.
/// GETs `<base>/v1/models` with a short timeout; any HTTP response — even
/// an error status — counts as reachable (something is listening), while
/// transport failures (connection refused, timeout) mean the suite should
/// skip rather than fail.
private actor ReachabilityDetector {
    private var cache: [URL: Bool] = [:]

    func isReachable(_ endpoint: URL) async -> Bool {
        if let cached = cache[endpoint] {
            return cached
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let probe = URLRequest(url: endpoint.appendingPathComponent("v1/models"))
        let reachable: Bool
        do {
            _ = try await session.data(for: probe)
            reachable = true
        } catch {
            reachable = false
        }
        cache[endpoint] = reachable
        return reachable
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
