import Foundation
import Providers
import SwiftMCP

/// A `RealtimeAgent` that wires `AppConfiguration` (instructions, voice,
/// transcription model, VAD mode) into a `RealtimeSessionConfiguration` and
/// exposes `LocalToolRegistry` as the agent's tool provider. The package's
/// `RealtimeSession` dispatches tool calls into the registry automatically via
/// `MCPToolProviding` — the registry is already `@MCPServer`-annotated.
final class RVARealtimeAgent: RealtimeAgent, @unchecked Sendable {
    typealias OutputType = String

    let name = "RVA"
    let instructions: String
    let toolProviders: [MCPToolProviding]
    let model: String?
    let sessionConfiguration: RealtimeSessionConfiguration

    init(configuration: AppConfiguration, toolRegistry: LocalToolRegistry) {
        instructions = configuration.instructions
        toolProviders = [toolRegistry]
        model = configuration.model

        let turnDetection: RealtimeSessionConfiguration.Audio.Input.TurnDetection? =
            configuration.useServerVAD
                ? .init(
                    type: "semantic_vad",
                    createResponse: true,
                    interruptResponse: true
                )
                : nil

        sessionConfiguration = RealtimeSessionConfiguration(
            audio: .init(
                input: .init(
                    format: .init(type: "audio/pcm", rate: 24_000),
                    turnDetection: turnDetection,
                    transcription: .init(model: configuration.transcriptionModel),
                    noiseReduction: .init(type: "near_field")
                ),
                output: .init(
                    format: .init(type: "audio/pcm", rate: 24_000),
                    voice: configuration.voice
                )
            ),
            instructions: configuration.instructions,
            outputModalities: [.audio]
        )
    }
}
