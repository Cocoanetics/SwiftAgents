import Foundation
import Providers

public enum RealtimeRunner {
    public static func connect(
        agent: some RealtimeAgent,
        model realtimeModel: (any RealtimeModel)? = nil
    ) async throws -> RealtimeSession {
        let modelIdentifier = agent.model ?? "gpt-realtime"
        let model = realtimeModel ?? OpenAIRealtimeWebSocketModel(model: modelIdentifier)
        let session = RealtimeSession(agent: agent, model: model, modelIdentifier: modelIdentifier)
        try await session.connect()
        return session
    }
}
