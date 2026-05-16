//
//  ChatCompletionAssembler.swift
//
//
//  Created by Oliver Drobnik on 14.05.24.
//

import Foundation

/**
 A class responsible for assembling and processing streaming chat completion chunks.
 This class handles chunks of data that may contain message and tool call deltas, updates the internal state accordingly,
 and provides a sorted list of completed choices with their respective messages and tool calls.
 */
public class ChatCompletionAssembler {
    // MARK: - Public Properties

    /// The chat completion choices assembled by the assembler.
    var choices: [ChatCompletionResponse.Choice] {
        return currentChoices.sorted(by: { $0.key < $1.key }).map { internalChoice in
            let (index, choice) = internalChoice

            if !model.hasPrefix("gpt") {
                if let functionCalls = choice.content?.extractFunctionCalls() {
                    let toolCalls = functionCalls.map { ToolCall(id: $0.name, type: "function", function: $0) }
                    let message = ChatMessage(role: choice.role ?? .assistant, content: .text(""), toolCalls: toolCalls)
                    return ChatCompletionResponse.Choice(message: message, finishReason: .toolCalls, index: index)
                }
            }

            let message = ChatMessage(
                role: choice.role ?? .assistant,
                content: choice.content.map { .text($0) },
                toolCalls: !choice.toolCalls.isEmpty ? choice.toolCalls : nil
            )
            return ChatCompletionResponse.Choice(message: message, finishReason: choice.finishReason, index: index)
        }
    }

    public var response: ChatCompletionResponse {
        return ChatCompletionResponse(id: id, object: "", created: Date(), model: model, usage: usage, choices: choices)
    }

    /// The identifier of the chat completion.
    var id: String!

    /// The model used for the completion
    var model: String!

    /// The system fingerprint
    var systemFingerprint: String?

    /// The total usage of all completion chunks.
    var usage: Usage?

    public init() {}

    // MARK: - Internals

    /// A struct representing an internal choice with associated tool calls.
    fileprivate struct InternalChoice {
        let index: Int
        var finishReason: FinishReason?
        var role: Role?
        var content: String?

        fileprivate var toolCallsDict: [Int: ToolCall] = [:]

        var toolCalls: [ToolCall] {
            return toolCallsDict.sorted(by: { $0.key < $1.key }).map(\.value)
        }
    }

    /// A dictionary of current choices indexed by their choice index.
    private var currentChoices: [Int: InternalChoice] = [:]

    // MARK: - Public Functions

    /**
     Processes a `Chunk` and updates the current state with the deltas from the chunk's choices.

     - Parameter chunk: The `Chunk` object containing choices with potential message and tool call deltas.
     */
    public func processChunk(_ chunk: Chunk) {
        id = chunk.id
        model = chunk.model

        if let systemFingerprint = chunk.systemFingerprint {
            self.systemFingerprint = systemFingerprint
        }

        if let usage = chunk.usage {
            self.usage = usage
        }

        for choice in chunk.choices {
            if var existingChoice = currentChoices[choice.index] {
                existingChoice.content = (existingChoice.content ?? "") + (choice.delta.content ?? "")
                existingChoice.finishReason = choice.finishReason ?? existingChoice.finishReason
                existingChoice.role = choice.delta.role ?? existingChoice.role

                appendToolCallDeltas(from: choice, to: &existingChoice.toolCallsDict)

                currentChoices[choice.index] = existingChoice
            } else {
                var newChoice = InternalChoice(
                    index: choice.index,
                    finishReason: choice.finishReason,
                    role: choice.delta.role,
                    content: choice.delta.content
                )

                appendToolCallDeltas(from: choice, to: &newChoice.toolCallsDict)

                currentChoices[choice.index] = newChoice
            }
        }
    }

    // MARK: - Internal Functions

    /**
     Appends tool call deltas from a `Chunk.Choice` to the specified tool calls dictionary.

     - Parameters:
     - choice: The `Chunk.Choice` object containing tool call deltas.
     - toolCalls: The dictionary of tool calls to append the deltas to.
     */
    private func appendToolCallDeltas(from choice: Chunk.Choice, to toolCalls: inout [Int: ToolCall]) {
        guard let toolCallDeltas = choice.delta.toolCalls else { return }

        for delta in toolCallDeltas {
            guard let index = delta.index else {
                continue
            }

            if toolCalls[index] == nil {
                toolCalls[index] = ToolCall(id: delta.id ?? "", type: delta.type ?? "", function: nil)
            }

            if let functionDelta = delta.function {
                var functionCall = toolCalls[index]?.function
                updateFunctionCall(&functionCall, with: functionDelta)
                toolCalls[index]?.function = functionCall
            }
        }
    }

    /**
     Updates a `FunctionCall` object with the values from a `FunctionCallDelta`.

     - Parameters:
     - functionCall: The `FunctionCall` object to be updated.
     - delta: The `FunctionCallDelta` containing new values to be appended.
     */
    private func updateFunctionCall(_ functionCall: inout FunctionCall?, with delta: FunctionCallDelta) {
        if functionCall == nil {
            functionCall = FunctionCall(name: delta.name ?? "", arguments: delta.arguments ?? "")
        } else {
            if let name = delta.name {
                functionCall?.name += name
            }

            if let arguments = delta.arguments {
                functionCall?.arguments += arguments
            }
        }
    }
}
