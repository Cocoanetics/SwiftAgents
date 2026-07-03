import Foundation
import Providers

/** Configuration options for running an agent workflow

 Per-run configuration for `Runner.run` / `Runner.runStreamed`. The run's
 provider is resolved from the model string via the shared `ProviderRegistry`
 (OpenAI, Anthropic, Google, Ollama, LM Studio, …) — or supplied directly
 through ``api``, bypassing name-based routing.
 */
public struct RunConfig: Sendable {
    /// The model to use for a run
    public var model: String?

    /// An explicit transport for this run, bypassing provider-name routing.
    ///
    /// Set this to hand a run its own connection-oriented client — most
    /// notably an ``OpenAIResponsesWebSocket``, which a caller builds (and
    /// optionally `warmup`s) per session so each run owns its own socket.
    /// When `nil`, the run resolves its provider from `model` via the shared
    /// `ProviderRegistry` as before. The injected instance flows through the
    /// same stateful/chat-completion detection as a registry-resolved one.
    public var api: API?

    /// Per-run override of the output modalities to request, e.g.
    /// `[.image(.init(size: "2K"))]`. When non-nil it replaces what the agent
    /// declares via `RequestsMedia` for this run, mirroring how `model`
    /// overrides the agent's default. When nil the agent's value is used.
    public var requestedMedia: [RequestedMedia]?

    /// The work flow name, used for tracing spans if no other name is set
    var workFlowName: String

    /// The strategy to use in decoding dates. Defaults to `.iso8601`.
    var dateDecodingStrategy = JSONDecoder.DateDecodingStrategy.iso8601

    /// Guardrails evaluated on the very first input before the agent loop.
    var inputGuardrails: [any InputGuardrail] = []

    /// Guardrails evaluated on the final output before returning from Runner.run.
    var outputGuardrails: [any OutputGuardrail] = []

    /** Initialize a new RunConfig

     - Parameters:
        - model: Optional model identifier, routed to any registered provider
          (e.g. "gpt-4.1", "claude-sonnet-4-5", "lmstudio/qwen3-coder"). If nil,
          uses the agent's default model
        - api: Optional explicit transport for this run, bypassing provider-name
          routing — e.g. a per-session ``OpenAIResponsesWebSocket``
        - requestedMedia: Optional per-run override of the output modalities to
          request, replacing what the agent declares via `RequestsMedia`
        - workFlowName: Name for the workflow, used for tracing spans. Defaults
          to "Agent Workflow"
        - dateDecodingStrategy: Strategy for decoding dates in provider
          responses. Defaults to `.iso8601`
     */
    public init(
        model: String? = nil,
        api: API? = nil,
        requestedMedia: [RequestedMedia]? = nil,
        workFlowName: String = "Agent Workflow",
        dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .iso8601
    ) {
        self.model = model
        self.api = api
        self.requestedMedia = requestedMedia
        self.workFlowName = workFlowName
        self.dateDecodingStrategy = dateDecodingStrategy
    }
}
