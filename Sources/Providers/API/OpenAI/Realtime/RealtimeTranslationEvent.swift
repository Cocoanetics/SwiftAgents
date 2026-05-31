import Foundation
import SwiftMCP

/// Configuration for a live speech-to-speech translation session against the
/// `gpt-realtime-translate` model.
///
/// The source language is detected automatically — only the target language is
/// required. Set `transcriptionModel` to also receive a transcript of the
/// source audio (`RealtimeTranslationEvent.sourceTranscriptDelta`).
public struct RealtimeTranslationConfiguration: Sendable, Equatable {
    /// ISO 639-1 code of the language to translate *into* (e.g. "de", "en").
    public var targetLanguage: String
    /// Transcription model for the source-language audio (e.g.
    /// "gpt-realtime-whisper"). When `nil`, no source transcript is produced.
    public var transcriptionModel: String?
    /// Optional input noise-reduction profile: "near_field" or "far_field".
    public var inputNoiseReduction: String?

    public init(
        targetLanguage: String,
        transcriptionModel: String? = nil,
        inputNoiseReduction: String? = nil
    ) {
        self.targetLanguage = targetLanguage
        self.transcriptionModel = transcriptionModel
        self.inputNoiseReduction = inputNoiseReduction
    }
}

/// An event from a live translation session.
///
/// The translations endpoint streams a continuous result — there is no turn
/// lifecycle and no per-utterance "done" event. Transcript deltas are token
/// fragments that the consumer accumulates; audio deltas are PCM16 chunks to
/// be played back in order.
public enum RealtimeTranslationEvent: Sendable {
    /// `session.created` / `session.updated` acknowledged by the server.
    case sessionConfigured
    /// Incremental transcript of the source-language audio
    /// (`session.input_transcript.delta`). Only emitted when a transcription
    /// model is configured.
    case sourceTranscriptDelta(String)
    /// Incremental translated text in the target language
    /// (`session.output_transcript.delta`).
    case translationTranscriptDelta(String)
    /// A chunk of translated audio, PCM16 mono 24 kHz
    /// (`session.output_audio.delta`, already base64-decoded).
    case audioDelta(Data)
    /// A server-side `error` event.
    case error(ErrorDetail)
    /// An event this client does not model yet — surfaced for diagnostics and
    /// forward compatibility.
    case raw([String: JSONValue])
}
