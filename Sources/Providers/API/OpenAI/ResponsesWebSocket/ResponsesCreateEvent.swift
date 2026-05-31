//
//  ResponsesCreateEvent.swift
//  SwiftAgents
//
//  The `{"type":"response.create", …}` envelope sent over the Responses
//  WebSocket. It carries the same field set as the HTTP `ResponseOptionals`
//  body **minus** `stream` and `background` (which have no meaning on the
//  socket), **plus** an optional `generate` flag used for `generate:false`
//  warmups.
//
//  Modeling it as its own type — rather than reusing `ResponseOptionals` —
//  means the socket can never accidentally emit `stream`/`background`: the
//  fields simply don't exist here. Encoding goes through the shared
//  `openAI.encoder`, so every field serializes byte-for-byte identically to
//  the HTTP path (snake_case keys, `previous_response_id`, etc.), and the
//  encoder's nil-omission keeps `generate` off the wire for normal turns.
//

import Foundation

/// A `response.create` event for the Responses WebSocket transport.
struct ResponsesCreateEvent: Encodable, @unchecked Sendable {
    /// Event discriminator. Always `response.create`.
    let type = "response.create"

    /// `false` pre-stages tools/instructions/input without producing output (a
    /// warmup); `nil` for a normal generating turn. Never `true` — that is the
    /// implicit default, so it stays off the wire.
    let generate: Bool?

    // MARK: Mirror of `ResponseOptionals` (minus `stream` / `background`)

    let input: Response.Input
    let model: String
    let contextManagement: [Response.ContextManagement]?
    let conversation: String?
    let include: [Include]?
    let instructions: String?
    let maxOutputTokens: Int?
    let maxToolCalls: Int?
    let metadata: [String: String]?
    let parallelToolCalls: Bool?
    let previousResponseId: String?
    let prompt: Response.Prompt?
    let promptCacheKey: String?
    let promptCacheRetention: Response.PromptCacheRetention?
    let reasoning: Reasoning?
    let safetyIdentifier: String?
    let serviceTier: ServiceTier?
    let store: Bool?
    let temperature: Double?
    let text: TextConfiguration?
    let toolChoice: ToolChoice?
    let tools: [Tool]?
    let topP: Double?
    let truncation: Response.TruncationStrategy?
    let user: String?

    init(
        input: Response.Input,
        model: String,
        generate: Bool? = nil,
        contextManagement: [Response.ContextManagement]? = nil,
        conversation: String? = nil,
        include: [Include]? = nil,
        instructions: String? = nil,
        maxOutputTokens: Int? = nil,
        maxToolCalls: Int? = nil,
        metadata: [String: String]? = nil,
        parallelToolCalls: Bool? = nil,
        previousResponseId: String? = nil,
        prompt: Response.Prompt? = nil,
        promptCacheKey: String? = nil,
        promptCacheRetention: Response.PromptCacheRetention? = nil,
        reasoning: Reasoning? = nil,
        safetyIdentifier: String? = nil,
        serviceTier: ServiceTier? = nil,
        store: Bool? = nil,
        temperature: Double? = nil,
        text: TextConfiguration? = nil,
        toolChoice: ToolChoice? = nil,
        tools: [Tool]? = nil,
        topP: Double? = nil,
        truncation: Response.TruncationStrategy? = nil,
        user: String? = nil
    ) {
        self.input = input
        self.model = model
        self.generate = generate
        self.contextManagement = contextManagement
        self.conversation = conversation
        self.include = include
        self.instructions = instructions
        self.maxOutputTokens = maxOutputTokens
        self.maxToolCalls = maxToolCalls
        self.metadata = metadata
        self.parallelToolCalls = parallelToolCalls
        self.previousResponseId = previousResponseId
        self.prompt = prompt
        self.promptCacheKey = promptCacheKey
        self.promptCacheRetention = promptCacheRetention
        self.reasoning = reasoning
        self.safetyIdentifier = safetyIdentifier
        self.serviceTier = serviceTier
        self.store = store
        self.temperature = temperature
        self.text = text
        self.toolChoice = toolChoice
        self.tools = tools
        self.topP = topP
        self.truncation = truncation
        self.user = user
    }
}
