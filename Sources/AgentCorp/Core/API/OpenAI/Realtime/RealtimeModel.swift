import Foundation
import SwiftMCP

public protocol RealtimeModel: Sendable {
	func connect() async throws -> AsyncThrowingStream<RealtimeServerEvent, Error>
	func send<Event: Encodable & Sendable>(_ event: Event) async throws
	func sendRaw(_ payload: [String: JSONValue]) async throws
	func disconnect() async
}
