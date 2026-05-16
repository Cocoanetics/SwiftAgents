import Foundation

/** Result of a completed agent workflow run
 
 Generic struct that holds the final output of an agent workflow execution.
 
 - Type Parameter T: The type of the final output value
 */
public struct RunResult<T: Sendable>: Sendable {
    /** The final output value produced by the agent workflow */
    public var finalOutput: T

	public var finalReasoning: String?
}
