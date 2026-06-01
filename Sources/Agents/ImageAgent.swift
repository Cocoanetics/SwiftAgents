//
//  ImageAgent.swift
//  SwiftAgents
//
//  An agent whose output is a generated image. It declares an image
//  `requestedMedia` intent; the Runner realizes it per provider (the OpenAI
//  Responses `image_generation` tool, or Gemini's request-level
//  `responseModalities` + `imageConfig`) and surfaces the rendered bytes as a
//  `GeneratedFile` on `RunResult.finalOutput`.
//

import Foundation
import Providers
import SwiftMCP

/// An agent whose output is a generated image, working across providers (OpenAI
/// and Gemini) from one declarative image intent — the Runner translates it to
/// each provider's mechanism.
///
/// Unlike `BasicAgent` (whose output is text), `ImageAgent`'s `OutputType` is
/// `GeneratedFile`, so a run returns the image bytes directly:
///
/// ```swift
/// let agent = ImageAgent(
///     name: "ImageGen",
///     model: "gpt-5.5",
///     instructions: "Generate the requested image.",
///     image: ImageOptions(quality: "low")
/// )
/// let result = try await Runner.run(agent: agent, input: "A red bicycle")
/// try result.finalOutput.data.write(to: outputURL)
/// ```
///
/// Multi-turn editing works two ways:
///   - resume the chain with `previousResponseId: result.lastResponseId`, or
///   - refer to the image by ID via an `image_generation_call` input item
///     built from `result.finalOutput.id`.
public final class ImageAgent: Agent, RequestsMedia, @unchecked Sendable {
    public typealias OutputType = GeneratedFile

    /// The image-output options this agent declares. The Runner realizes them
    /// per provider (the OpenAI `image_generation` tool, or Gemini's
    /// `responseModalities` + `imageConfig`).
    public let image: ImageOptions

    /// `RequestsMedia` — this agent always wants a single image output.
    public var requestedMedia: [RequestedMedia] { [.image(image)] }

    /// The name of the agent.
    public let name: String

    /// The instructions that define the agent's behavior.
    public let instructions: String

    /// A description of the agent, used when the agent is a handoff target.
    public let handoffDescription: String?

    /// Tool providers available to the agent.
    public let toolProviders: [MCPToolProviding]

    /// Extra tools the caller supplied. The `image_generation` tool is not
    /// among them — the Runner injects it from the image intent when the run
    /// targets OpenAI. Supplying an explicit `image_generation` tool here
    /// overrides that injection.
    public let tools: [Tool]

    /// MCP servers to include as tools.
    public let mcpServers: [MCPServerProxy]

    /// Handoffs available to the agent.
    public let handoffs: [any Handoff]

    /// An override to specify the mainline model to be used. Must support the
    /// `image_generation` tool (e.g. `gpt-5` and newer).
    public let model: String?

    /// Model settings to apply.
    public let modelSettings: ModelSettings

    /// Guardrails evaluated on the first input before the agent loop.
    public let inputGuardrails: [any InputGuardrail]

    /// Guardrails evaluated on the final output before returning.
    public let outputGuardrails: [any OutputGuardrail]

    /// Creates an image-generating agent.
    ///
    /// - Parameters:
    ///   - name: The name of the agent.
    ///   - model: The mainline model driving the conversation. On OpenAI it must
    ///     support the `image_generation` tool.
    ///   - instructions: The instructions that define the agent's behavior.
    ///   - image: The image-output options (size, quality, format, action, …)
    ///     in one structure. The Runner realizes them per provider; defaults to
    ///     an empty `ImageOptions` (provider defaults).
    ///   - tools: Extra tools to expose. Supplying an explicit `image_generation`
    ///     tool here overrides the one the Runner would inject.
    ///   - toolProvider: Tool providers available to the agent.
    public init(
        name: String,
        model: String? = nil,
        instructions: String = "Generate or edit the requested image.",
        image: ImageOptions = ImageOptions(),
        handoffDescription: String? = nil,
        tools: [Tool] = [],
        toolProvider: [MCPToolProviding] = [],
        mcpServers: [MCPServerProxy] = [],
        modelSettings: ModelSettings = ModelSettings(),
        handoffs: [any Handoff] = [],
        inputGuardrails: [any InputGuardrail] = [],
        outputGuardrails: [any OutputGuardrail] = []
    ) {
        // ImageAgent is purely declarative: it just stores the image options
        // and exposes them via `RequestsMedia.requestedMedia`. The Runner
        // realizes that intent per provider (the OpenAI Responses
        // `image_generation` tool, or Gemini's `responseModalities` +
        // `imageConfig`); no provider-specific tool assembly happens here.
        self.image = image

        self.name = name
        self.instructions = instructions
        self.handoffDescription = handoffDescription
        toolProviders = toolProvider
        self.tools = tools
        self.mcpServers = mcpServers
        self.modelSettings = modelSettings
        self.handoffs = handoffs
        self.model = model
        self.inputGuardrails = inputGuardrails
        self.outputGuardrails = outputGuardrails
    }
}
