//
//  RunStep.swift
//
//
//  Created by Oliver Drobnik on 03.05.24.
//

import Foundation

/**
 Represents the steps (model and tool calls) taken during the run.

 see also: [Run Steps API Reference](https://platform.openai.com/docs/api-reference/run-steps)
 */
public struct RunStep: Codable {
    /// The identifier of the run step.
    public let id: String

    /// The object type, which is always "thread.run.step".
    public let object: String

    /// The timestamp for when the run step was created.
    public let createdAt: Date

    /// The ID of the assistant associated with the run step.
    public let assistantId: String

    /// The ID of the thread that was run.
    public let threadId: String

    /// The ID of the run that this run step is a part of.
    public let runId: String

    /// The type of run step.
    public let type: StepType

    /// The status of the run step.
    public let status: Status

    /// The details of the run step.
    public let stepDetails: Details

    /// Optional last error details associated with the run step.
    public let lastError: LastError?

    // MARK: - Enums

    /// Represents the status of a run step.
    public enum Status: String, Codable {
        case inProgress = "in_progress"
        case cancelled
        case failed
        case completed
        case expired
    }

    /// Represents the type of a run step.
    public enum StepType: String, Codable {
        case messageCreation = "message_creation"
        case toolCalls = "tool_calls"
    }

    // MARK: - Structs

    /// Represents the details of a run step.
    public struct Details: Codable {
        /// The type of the run step details.
        let type: String

        /// The details of message creation by a run step.
        let messageCreation: MessageCreation?

        /// The tool calls made during the run step.
        let toolCalls: [ToolCall]?

        // MARK: - Structs

        /// Represents the details of message creation by a run step.
        public struct MessageCreation: Codable {
            /// The identifier of the created message.
            let messageId: String
        }

        /// Represents a tool call made during the run step.
        public struct ToolCall: Codable {
            /// The identifier of the tool call.
            let id: String

            /// The type of tool call.
            let type: String

            /// Details of a file search tool call.
            let fileSearch: [String: String]?

            /// Details of a function tool call.
            let function: Function?

            /// Details of a code interpreter tool call.
            let codeInterpreter: CodeInterpreter?

            /// Represents the details of a function tool call.
            public struct Function: Codable {
                /// The name of the function.
                let name: String

                /// The arguments passed to the function.
                let arguments: String

                /// The output of the function.
                let output: String
            }

            /// Represents the details of a code interpreter tool call.
            public struct CodeInterpreter: Codable {
                /// The input to the code interpreter.
                let input: String

                /// The outputs from the code interpreter.
                let outputs: [Output]

                // Represents the output of a code interpreter tool call.
                // swiftlint:disable:next nesting
                public struct Output: Codable {
                    /// The type of the output.
                    let type: String

                    /// The image output from the code interpreter tool call.
                    let image: ImageFile?

                    /// The log output from the code interpreter tool call.
                    let logs: String?
                }
            }
        }
    }
}
