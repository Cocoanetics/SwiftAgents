//
//  ImageAgent.swift
//  SwiftAgents
//
//  An agent whose output is a generated image. It wires the Responses API
//  `image_generation` built-in tool into every turn and surfaces the rendered
//  bytes as a `GeneratedFile` on `RunResult.finalOutput`.
//

import Foundation
import Providers
import SwiftMCP

/// An agent that generates and edits images via the OpenAI Responses API
/// `image_generation` built-in tool.
///
/// Unlike `BasicAgent` (whose output is text), `ImageAgent`'s `OutputType` is
/// `GeneratedFile`, so a run returns the image bytes directly:
///
/// ```swift
/// let agent = ImageAgent(
///     name: "ImageGen",
///     model: "gpt-5.5",
///     instructions: "Generate the requested image.",
///     quality: "low"
/// )
/// let result = try await Runner.run(agent: agent, input: "A red bicycle")
/// try result.finalOutput.data.write(to: outputURL)
/// ```
///
/// Multi-turn editing works two ways:
///   - resume the chain with `previousResponseId: result.lastResponseId`, or
///   - refer to the image by ID via an `image_generation_call` input item
///     built from `result.finalOutput.id`.
public final class ImageAgent: Agent, @unchecked Sendable {
    public typealias OutputType = GeneratedFile

    /// The name of the agent.
    public let name: String

    /// The instructions that define the agent's behavior.
    public let instructions: String

    /// A description of the agent, used when the agent is a handoff target.
    public let handoffDescription: String?

    /// Tool providers available to the agent.
    public let toolProviders: [MCPToolProviding]

    /// Tools available to the agent — always includes the configured
    /// `image_generation` tool, plus any extras the caller supplied.
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
    ///   - model: The mainline model driving the conversation. Must support the
    ///     `image_generation` tool.
    ///   - instructions: The instructions that define the agent's behavior.
    ///   - imageModel: The image model the tool should use (e.g. `gpt-image-2`);
    ///     nil lets the API pick its default.
    ///   - action: Whether to always generate, force an edit, or auto-select.
    ///   - size: Output dimensions, e.g. `1024x1024`, `auto`.
    ///   - quality: Rendering quality: `low`, `medium`, `high`, `auto`.
    ///   - background: `opaque`, `transparent`, or `auto`.
    ///   - outputFormat: `png`, `jpeg`, or `webp`.
    ///   - outputCompression: Compression (0–100) for `jpeg`/`webp`.
    ///   - moderation: `auto` or `low`.
    ///   - partialImages: Number of partial images (0–3) to stream.
    ///   - inputImageMask: Mask marking the editable region of the first input image.
    ///   - tools: Extra tools to expose alongside `image_generation`.
    ///   - toolProvider: Tool providers available to the agent.
    public init(
        name: String,
        model: String? = nil,
        instructions: String = "Generate or edit the requested image.",
        imageModel: String? = nil,
        action: ImageGenerationTool.Action? = nil,
        size: String? = nil,
        quality: String? = nil,
        background: String? = nil,
        outputFormat: String? = nil,
        outputCompression: Int? = nil,
        moderation: String? = nil,
        partialImages: Int? = nil,
        inputImageMask: ImageGenerationTool.InputImageMask? = nil,
        handoffDescription: String? = nil,
        tools: [Tool] = [],
        toolProvider: [MCPToolProviding] = [],
        mcpServers: [MCPServerProxy] = [],
        modelSettings: ModelSettings = ModelSettings(),
        handoffs: [any Handoff] = [],
        inputGuardrails: [any InputGuardrail] = [],
        outputGuardrails: [any OutputGuardrail] = []
    ) {
        let imageTool = Tool.imageGeneration(ImageGenerationTool(
            model: imageModel,
            action: action,
            size: size,
            quality: quality,
            background: background,
            outputFormat: outputFormat,
            outputCompression: outputCompression,
            moderation: moderation,
            partialImages: partialImages,
            inputImageMask: inputImageMask
        ))

        self.name = name
        self.instructions = instructions
        self.handoffDescription = handoffDescription
        toolProviders = toolProvider
        self.tools = [imageTool] + tools
        self.mcpServers = mcpServers
        self.modelSettings = modelSettings
        self.handoffs = handoffs
        self.model = model
        self.inputGuardrails = inputGuardrails
        self.outputGuardrails = outputGuardrails
    }
}
