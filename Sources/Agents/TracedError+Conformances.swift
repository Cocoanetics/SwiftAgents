import Foundation
import Providers
import SwiftMCP
import Tracing

extension RunnerError: TracedError {
    public var spanErrorMessage: String {
        switch self {
            case .exceededMaxTurns:
                return "Exceeded maximum number of turns"
        }
    }
}

extension InputGuardrailTripwireTriggered: TracedError {
    public var spanErrorMessage: String { "Input guardrail tripwire triggered" }
    public var spanErrorData: [String: JSONValue]? {
        ["guardrail": JSONValue(guardrailName)]
    }
}

extension OutputGuardrailTripwireTriggered: TracedError {
    public var spanErrorMessage: String { "Output guardrail tripwire triggered" }
    public var spanErrorData: [String: JSONValue]? {
        ["guardrail": JSONValue(guardrailName)]
    }
}
