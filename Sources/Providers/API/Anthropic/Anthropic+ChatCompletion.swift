//
//  Anthropic+ChatCompletion.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 25.05.26.
//
//  The `createChatCompletion`/`createChatCompletionStream` overrides live in
//  `Anthropic.swift` (Swift doesn't allow `override` from an extension). This
//  file holds the static helper that maps an `AnthropicMessagesResponse` onto
//  the OpenAI-shaped `ChatCompletionResponse`.

import Foundation

extension Anthropic {
    /// Wraps Anthropic's response into an OpenAI-shaped `ChatCompletionResponse`.
    static func makeChatCompletionResponse(
        model: String,
        response: AnthropicMessagesResponse
    ) -> ChatCompletionResponse {
        let fold = chatMessage(from: response.content)
        let finishReason = chatFinishReason(from: response.stopReason)

        let choice = ChatCompletionResponse.Choice(
            message: fold.message,
            finishReason: finishReason,
            index: 0
        )

        return ChatCompletionResponse(
            id: response.id,
            object: "chat.completion",
            created: Date(),
            model: response.model.isEmpty ? model : response.model,
            usage: usage(from: response.usage),
            choices: [choice]
        )
    }
}
