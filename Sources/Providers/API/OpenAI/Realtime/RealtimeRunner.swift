import Foundation

public enum RealtimeRunner {
	public static func connect<A: RealtimeAgent>(
		agent: A,
		model realtimeModel: (any RealtimeModel)? = nil
	) async throws -> RealtimeSession {
		let modelIdentifier = agent.model ?? "gpt-realtime"
		let model = realtimeModel ?? OpenAIRealtimeWebSocketModel(model: modelIdentifier)
		let session = RealtimeSession(agent: agent, model: model, modelIdentifier: modelIdentifier)
		try await session.connect()
		return session
	}
}
