//
//  Runner+Guardrails.swift
//  SwiftAgents
//
//  Input-guardrail machinery split out of Runner.swift to keep the main
//  actor body focused on the per-turn state machine: the parallel
//  agent-vs-guardrail task group (`executeWithInputGuardrails`), its
//  result/continuation carrier, and the turn-state box that hands the
//  final `TurnState` back across the Swift 6 `sending` boundary.

import Foundation
import Providers
import Tracing

/// Enum to represent outcomes from the task group for guardrails
private enum GuardrailOutcome<OutputType: Sendable>: @unchecked Sendable {
    case agent(AgentResult<OutputType>)
    case guardrail(name: String, result: InputGuardrailResult)
    case taskError(Error)
}

extension Runner {
    /// Reference box that lets the agent child task own and mutate a
    /// `TurnState`, then hand the final value back to the parent after the
    /// task group completes — without the parent sharing a mutable `var`
    /// capture (which Swift 6 forbids across the `sending` boundary).
    ///
    /// `@unchecked Sendable` is sound here: the child task is the only writer,
    /// and the parent reads `value` only after awaiting the group, which
    /// establishes a happens-after ordering with no overlapping access.
    private final class TurnStateBox: @unchecked Sendable {
        var value: TurnState
        init(_ value: TurnState) { self.value = value }
    }

    /// Result type for the executeWithInputGuardrails function to include continuation state
    struct GuardrailExecutionResult<T> {
        let result: AgentResult<T>
        let continuation: ContinuationState

        enum ContinuationState {
            case completed
            case continueWithState(state: TurnState)
        }
    }

    // Helper function for executing an agent with input guardrails
    static func executeWithInputGuardrails<A: Agent>(
        agent: A,
        input: String,
        agentSpan: TraceSpan,
        tools: [Tool],
        maxTurns: Int,
        model: String,
        api: API,
        nextInput: Response.Input,
        session: Providers.Session,
        tracker: ConversationStateTracker,
        decoder: JSONDecoder,
        config: RunConfig
    ) async throws -> GuardrailExecutionResult<A.OutputType> {
        // Initialize turn state
        let turnStateBox = TurnStateBox(TurnState(
            nextInput: nextInput,
            turns: 0
        ))

        // Same override precedence as the non-guardrail path.
        let requestedMedia = config.requestedMedia ?? (agent as? RequestsMedia)?.requestedMedia ?? []

        // Track if the agent finished before any guardrail
        var agentFinishedFirst = false
        var guardrailResults: [(name: String, result: InputGuardrailResult)] = []
        var storedAgentResult: AgentResult<A.OutputType>?
        var firstEncounteredError: Error?

        return try await withThrowingTaskGroup(of: GuardrailOutcome<A.OutputType>.self) { group in
            // Start agent task
            group.addTask {
                do {
                    var localTurnState = turnStateBox.value
                    let result = try await executeAgentTurns(
                        agent: agent,
                        agentSpan: agentSpan,
                        tools: tools,
                        maxTurns: maxTurns,
                        model: model,
                        api: api,
                        requestedMedia: requestedMedia,
                        turnState: &localTurnState,
                        session: session,
                        tracker: tracker,
                        decoder: decoder
                    )
                    turnStateBox.value = localTurnState
                    return .agent(result)
                } catch {
                    return .taskError(error)
                }
            }

            // Start each guardrail task
            for inputGuardrail in agent.inputGuardrails + config.inputGuardrails {
                group.addTask {
                    do {
                        // Use withSpan for the guardrail evaluation
                        let evaluationResult = try await withSpan { span in
                            let result = try await inputGuardrail.evaluate(input)
                            span.spanData = GuardrailSpanData(
                                name: inputGuardrail.name,
                                triggered: result.tripwireTriggered
                            )
                            return result
                        }
                        return .guardrail(name: inputGuardrail.name, result: evaluationResult)
                    } catch {
                        // If withSpan or evaluate throws, record the error and propagate
                        TraceContext.currentSpan?.spanData = GuardrailSpanData(
                            name: inputGuardrail.name,
                            triggered: false
                        )
                        return .taskError(error)
                    }
                }
            }

            var triggeredGuardrailError: Error?

            // Process results from tasks
            while let outcome = await group.nextResult() {
                switch outcome {
                    case let .success(guardrailOutcome):
                        switch guardrailOutcome {
                            case let .agent(result):
                                if triggeredGuardrailError == nil {
                                    storedAgentResult = result
                                    agentFinishedFirst = true
                                }
                            case let .guardrail(name, gResult):
                                guardrailResults.append((name, gResult))
                                if gResult.tripwireTriggered, triggeredGuardrailError == nil {
                                    // First guardrail to trigger
                                    triggeredGuardrailError = InputGuardrailTripwireTriggered(
                                        guardrailName: name,
                                        result: gResult
                                    )
                                    group.cancelAll() // Cancel other tasks
                                }
                            case let .taskError(err):
                                if triggeredGuardrailError == nil, firstEncounteredError == nil {
                                    firstEncounteredError = err
                                }
                        }
                    case let .failure(error):
                        if triggeredGuardrailError == nil, firstEncounteredError == nil {
                            firstEncounteredError = error
                        }
                }
            }

            // If the agent finished first, but a guardrail result triggered later, throw the guardrail error
            if agentFinishedFirst {
                if let tripped = guardrailResults.first(where: { $0.result.tripwireTriggered }) {
                    throw InputGuardrailTripwireTriggered(
                        guardrailName: tripped.name,
                        result: tripped.result
                    )
                }
            }

            // Prioritize throwing the specific guardrail tripwire error
            if let specificError = triggeredGuardrailError as? InputGuardrailTripwireTriggered {
                throw specificError
            }

            // If a guardrail didn't trigger, but an agent or guardrail task failed, throw that error
            if let errorToThrow = firstEncounteredError {
                throw errorToThrow
            }

            // If agent completed successfully and no guardrail triggered, return the stored result
            if let result = storedAgentResult {
                return GuardrailExecutionResult(
                    result: result,
                    continuation: .continueWithState(state: turnStateBox.value)
                )
            }

            // This should not be reached if logic is sound
            throw CancellationError()
        }
    }
}
