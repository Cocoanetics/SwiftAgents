//
//  ChatCompletionResponse+Response.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 15.05.25.
//

import Foundation
import Providers

public extension ChatCompletionResponse {
    func toResponse(input _: Response.Input, agent: any Agent, modelSettings: ModelSettings) -> Response {
        var outputItems: [OutputItem] = []
        for choice in choices {
            let message = choice.message

            var content: [OutputItem.MessageContent] = []

            // Deepseek API: reasoning comes in separate property
            if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                let reasoningOutput = OutputItem.ReasoningOutput(
                    id: UUID().uuidString,
                    status: .completed,
                    summary: [OutputItem.SummaryItem(type: "summary", text: reasoning)]
                )
                outputItems.append(.reasoning(reasoningOutput))
            }

            if let text = message.textContent, !text.isEmpty {
                // extract reasoning between think tags
                let (reasoning, contentText) = text.extractReasoning()

                if let reasoning, !reasoning.isEmpty {
                    let reasoningOutput = OutputItem.ReasoningOutput(
                        id: UUID().uuidString,
                        status: .completed,
                        summary: [OutputItem.SummaryItem(type: "summary", text: reasoning)]
                    )
                    outputItems.append(.reasoning(reasoningOutput))
                }

                // Add text content if present
                if !contentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    content.append(.outputText(OutputItem.OutputText(text: contentText, annotations: [])))
                }
            }

            // Inline image parts — providers like Gemini return generated
            // image bytes as an `image_url` content part (a `data:` URL) on a
            // normal completion rather than via a tool call. Carry them as
            // `outputImage` so `firstGeneratedFile` can surface the bytes.
            if let parts = message.contentParts {
                for part in parts {
                    guard let parsed = part.decodedImageData() else { continue }
                    content.append(.outputImage(OutputItem.OutputImage(
                        data: parsed.data,
                        mimeType: parsed.mimeType
                    )))
                }
            }

            if !content.isEmpty {
                let messageItem = OutputItem.message(OutputItem.MessageOutput(
                    id: UUID().uuidString,
                    role: .assistant,
                    status: .completed,
                    content: content
                ))
                outputItems.append(messageItem)
            }

            // Add tool calls if present
            if let toolCalls = message.toolCalls {
                for toolCall in toolCalls {
                    outputItems.append(.functionCall(OutputItem.FunctionCall(
                        id: UUID().uuidString,
                        callId: toolCall.id,
                        name: toolCall.function?.name ?? "",
                        arguments: toolCall.function?.arguments ?? "",
                        status: .completed
                    )))
                }
            }
        }

        // Convert Usage to ResponsesUsage
        let responsesUsage = usage.map { usage in
            ResponsesUsage(
                inputTokens: usage.promptTokens,
                inputTokensDetails: .init(cachedTokens: 0),
                outputTokens: usage.completionTokens,
                outputTokensDetails: .init(reasoningTokens: 0),
                totalTokens: usage.totalTokens
            )
        }

        return Response(
            id: "__fake_id__",
            createdAt: created,
            status: .completed,
            error: nil,
            incompleteDetails: nil,
            instructions: agent.instructions,
            maxOutputTokens: modelSettings.maxCompletionTokens,
            model: model,
            output: outputItems,
            parallelToolCalls: modelSettings.parallelToolCalls,
            previousResponseId: nil,
            reasoning: nil,
            temperature: modelSettings.temperature,
            text: .init(format: agent.outputType),
            toolChoice: .auto,
            tools: [],
            topP: modelSettings.topP,
            truncation: nil,
            usage: responsesUsage,
            user: nil,
            metadata: modelSettings.metadata,
            serviceTier: nil
        )
    }
}
