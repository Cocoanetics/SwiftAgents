import Foundation

struct TranscriptDelta: Sendable {
    let itemID: String
    let role: TranscriptRole
    let text: String
    var fullOutput: String?
    let isFinal: Bool
    let replace: Bool
}

struct AudioChunk: Sendable {
    let data: Data
    let itemID: String
    let contentIndex: Int
}

struct PlaybackInterrupt: Sendable {
    let itemID: String
    let contentIndex: Int
}

enum RealtimeServiceEvent: Sendable {
    case state(ConnectionState)
    case responseActive(Bool)
    case transcript(TranscriptDelta)
    case userSpeechDetected(Bool)
    case audioOutput(AudioChunk)
    case flushPlayback
    case interruptPlayback(PlaybackInterrupt)
    case hangupRequested
    case toolCallBegan
    case log(String)
}
