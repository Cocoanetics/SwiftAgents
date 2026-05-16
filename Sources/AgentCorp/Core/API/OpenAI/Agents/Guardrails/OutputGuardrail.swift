//
//  OutputGuardrail.swift
//  AgentCorp
//
//  Created by [Your Name] on [Date].
//

import Foundation
import SwiftMCP

/// An error specifically related to output guardrail operations.
public enum OutputGuardrailError: Error, LocalizedError {
    case processingError(String)

    public var errorDescription: String? {
        switch self {
        case .processingError(let message):
            return "Output guardrail processing error: \(message)"
        }
    }
}

/// Error thrown when an output guardrail's tripwire condition is met.
public struct OutputGuardrailTripwireTriggered: Error, LocalizedError, Sendable {
    /// The name of the guardrail that was triggered.
    public let guardrailName: String
    /// The full result from the guardrail evaluation.
    public let result: OutputGuardrailFunctionOutput

    public init(guardrailName: String, result: OutputGuardrailFunctionOutput) {
        self.guardrailName = guardrailName
        self.result = result
    }

    public var errorDescription: String? {
        "Output guardrail '\(guardrailName)' triggered: \(result.tripwireTriggered). Metadata: \(String(describing: result.metadata))".trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A protocol defining an output guardrail.
/// Output guardrails are checked against the final output produced by an agent
/// before it is returned as the result of a `Runner.run` call.
/// They only run for the *last agent* in a workflow that produces the final output.
public protocol OutputGuardrail: Sendable {
    /// A unique, descriptive name for the guardrail.
    var name: String { get }

    /// Validate the agent's candidate final output.
    /// - Parameters:
    ///   - output: The value the agent intends to return as its final output.
    ///   - agent: The agent that produced the output.
    func evaluate(_ output: any Sendable, agent: any Agent) async throws -> OutputGuardrailFunctionOutput
} 

public struct OutputGuardrailFunctionOutput: Sendable {
	public let metadata: [String: JSONValue]?
	public let tripwireTriggered: Bool
	public init(metadata: [String: JSONValue]? = nil, tripwireTriggered: Bool) {
		self.metadata = metadata
		self.tripwireTriggered = tripwireTriggered
	}
}

public struct OutputGuardrailResult: Sendable {
	public let guardrail: any OutputGuardrail
	public let agentOutput: JSONValue
	public let agent: any Agent
	public let output: OutputGuardrailFunctionOutput
}
