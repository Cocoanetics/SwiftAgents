import Foundation

/** Internal result type for agent execution steps

 This enum represents the possible outcomes of an agent's execution step:
 either a final output value or a handoff to another agent.

 - Type Parameter T: The type of the final output value
 */
enum AgentResult<T> {
    /** Indicates the agent has produced a final output value
     - Parameter T: The final output value
     */
    case finalOutput(T, String?)

    /** Indicates the agent is handing off execution to another agent
     - Parameter Agent: The agent to continue execution with
     */
    case handOff(any Agent)
}
