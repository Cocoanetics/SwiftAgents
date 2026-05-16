import Foundation
import SwiftMCP

/** Errors that can occur during agent workflow execution

 This enum defines the possible error conditions that may occur
 while running an agent workflow.
 */
public enum RunnerError: Error {
    /** Indicates the workflow has exceeded its maximum allowed number of turns

     This error is thrown when an agent workflow takes too many turns without
     reaching a final output or valid handoff, suggesting it may be stuck in a loop.
     */
    case exceededMaxTurns
}
