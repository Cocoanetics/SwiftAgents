import Foundation
import Providers
import SwiftMCP

// MARK: - Input Guardrail Protocol & Supporting Types

/// Result returned by an `InputGuardrail` evaluation.
public struct InputGuardrailResult: Sendable {
    /// Indicates whether the guardrail's tripwire was triggered.
    public let tripwireTriggered: Bool
    /// Optional additional data returned by the guardrail.
    public let metadata: [String: JSONValue]?

    public init(tripwireTriggered: Bool, metadata: [String: JSONValue]? = nil) {
        self.tripwireTriggered = tripwireTriggered
        self.metadata = metadata
    }
}

/// Protocol for synchronous or asynchronous input guardrails.
public protocol InputGuardrail: Sendable {
    /// A human-readable identifier for debugging/tracing.
    var name: String { get }
    /// Evaluate the guardrail against the initial user input.
    func evaluate(_ input: String) async throws -> InputGuardrailResult
}

/// Error thrown when any input guardrail triggers its tripwire.
public struct InputGuardrailTripwireTriggered: Error, LocalizedError, Sendable {
    public let guardrailName: String
    public let result: InputGuardrailResult

    public var errorDescription: String? {
        "Input guardrail '\(guardrailName)' triggered tripwire."
    }

    public init(guardrailName: String, result: InputGuardrailResult) {
        self.guardrailName = guardrailName
        self.result = result
    }
}
