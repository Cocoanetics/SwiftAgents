import Foundation

/** Configuration options for running an agent workflow

 This struct provides configuration parameters that control how an agent workflow executes.

 Properties:
 - model: Optional OpenAI model identifier to use for this run
 - workFlowName: Name identifier for the workflow being executed
 */
public struct RunConfig {
    /// The model to use for a run
    public var model: String?

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
        - model: Optional OpenAI model identifier. If nil, uses the agent's default model
        - workFlowName: Name for the workflow. Defaults to "Agent Workflow"
     */
    public init(
        model: String? = nil,
        workFlowName: String = "Agent Workflow",
        dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .iso8601
    ) {
        self.model = model
        self.workFlowName = workFlowName
        self.dateDecodingStrategy = dateDecodingStrategy
    }
}
