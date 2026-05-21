# RealtimeVoiceAgent

Prototype iPhone app for OpenAI Realtime voice conversations, built with SwiftUI and generated with `xcodegen`.

## What is in this repo

- A buildable iOS 17+ SwiftUI app target.
- A realtime service layer using `URLSessionWebSocketTask`.
- `AVAudioSession` + `AVAudioEngine` handling for microphone capture and speaker playback.
- Incremental transcript UI for user speech, assistant speech, and local tool activity.
- Local on-device tools:
  - `current_time`
  - `device_info`
  - `append_note`
  - `echo`
- Build-time configuration through `.xcconfig` and `Info.plist` substitution.

## Project layout

- `project.yml`: XcodeGen spec.
- `Config/`: shared build settings and local secrets template.
- `App/Sources/Services/Realtime`: websocket transport and session orchestration.
- `App/Sources/Services/Audio`: audio session and audio engine pipeline.
- `App/Sources/Services/Tools`: local tool registry and note persistence.
- `App/Sources/Features/Conversation`: SwiftUI screen and state management.

## Setup

1. Copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig`.
2. Fill in either:
   - `OPENAI_REALTIME_TOKEN_ENDPOINT`, preferred for a mobile prototype backed by your own server.
   - `OPENAI_API_KEY`, only for local prototyping.
3. Generate the project:

```sh
xcodegen generate
```

4. Open `RealtimeVoiceAgent.xcodeproj` in Xcode.
5. Build and run on an iPhone or simulator running iOS 17 or later.

## Configuration keys

- `OPENAI_API_KEY`
- `OPENAI_REALTIME_TOKEN_ENDPOINT`
- `OPENAI_REALTIME_WEBSOCKET_URL`
- `OPENAI_REALTIME_MODEL`
- `OPENAI_REALTIME_VOICE`
- `OPENAI_REALTIME_TRANSCRIPTION_MODEL`
- `OPENAI_REALTIME_USE_SERVER_VAD`
- `OPENAI_REALTIME_INSTRUCTIONS`

## Architecture notes

### Realtime

`OpenAIRealtimeService` owns session creation, websocket messaging, session updates, transcript event handling, and tool call completion.

The service currently uses the websocket transport because it is the cleanest prototype path inside a normal iOS app target. There are explicit TODO boundaries for production-oriented upgrades:

- swap direct API keys for backend-issued ephemeral tokens everywhere
- add reconnection/backoff logic
- add richer event coverage
- consider a WebRTC transport for lower-latency mobile audio behavior

### Audio

`AudioStreamCoordinator` captures microphone audio, converts it to 24kHz mono PCM16, and streams chunks to the realtime session. Assistant audio deltas are decoded from base64 PCM16 and scheduled through `AVAudioPlayerNode`.

The app configures:

- `AVAudioSession` category: `playAndRecord`
- mode: `voiceChat`
- background mode: `audio`
- microphone usage description in `Info.plist`

### Tools

The local tool layer is intentionally independent from the realtime transport. That keeps tool execution simple and makes it easier to swap in `AgentCorp` later.

Current tools return JSON string output back into the realtime conversation through `function_call_output`.

## AgentCorp status

I did not make the app target depend directly on `/Users/oliver/Developer/AgentCorp` for the first pass. The package already has useful tool abstractions, but it does not appear to provide a ready-made realtime voice transport or iOS audio session layer.

The app includes an `Integrations/AgentCorp` boundary so the following future enhancements are straightforward:

- realtime websocket or WebRTC transport types in AgentCorp
- typed realtime event models
- a direct bridge from local tool definitions to AgentCorp/OpenAI realtime tool schema
- reusable conversation state abstractions for streaming transcripts and tool calls

This keeps the prototype buildable without forcing the app target to resolve AgentCorp's full dependency graph.

## Background behavior truth

This prototype enables background audio and keeps the audio session active when possible, but it is not a guaranteed always-on voice agent.

Practical constraints on iOS:

- Background audio only helps while the app is actively playing or recording audio.
- If the audio session is interrupted, the app can still be suspended.
- The websocket connection is best-effort in the background; long-lived reliability is lower than a foreground session.
- This is not a CallKit or special VoIP entitlement implementation.
- The small `UIBackgroundTask` usage only adds short transition grace time; it does not create indefinite background execution.

If you need stronger background guarantees, plan on:

- foreground usage for the main prototype flow
- tighter interruption handling
- possibly a WebRTC-based transport path
- backend session recovery or resumability support

## Limitations

- No reconnection policy yet.
- No explicit mute or push-to-talk UI.
- No waveform visualisation.
- No persisted conversation history besides the note file tool.
- The token endpoint helper assumes a simple GET endpoint that returns either raw token text or JSON containing `client_secret.value`, `value`, or `token`.
- Direct API key mode is convenient for local testing but not appropriate for distribution.

## Notes on realism

This is a real prototype, not placeholder-only documentation. The app has working audio/session/tool plumbing, but the realtime API is still an evolving surface and some event/config fields may need small adjustments against the exact OpenAI account/model behavior you test with.

The service code intentionally keeps TODO markers around the parts most likely to change:

- mobile auth hardening
- transport choice
- reconnect semantics
- broader realtime event coverage
