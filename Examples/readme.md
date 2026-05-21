# Examples

Reference consumers of SwiftAgents. Each subfolder is a self-contained project that shows one way to build on top of the package.

## [Coder](Coder/) — terminal coding agent

In-process coding-agent CLI. Tool surface: `bash`, `read`, `write`, `edit`, `ls`, plus `apply_patch` for models that support it. Reference implementation of an `Agent` against the Responses API.

Still wired into the root [`Package.swift`](../Package.swift) as the `Coder` executable product, so:

```sh
swift run Coder --help
```

works from the repo root. The folder lives under `Examples/` to make its role explicit — it's a real product you can install, but its primary job is to show how the `Providers` runtime is meant to be consumed.

### API key

`Coder` reads `OPENAI_API_KEY` from the environment. Either export it in your shell:

```sh
export OPENAI_API_KEY=sk-...
swift run Coder
```

or drop it into a `.env` file in the working directory you point `Coder` at (loaded automatically via `SwiftDotenv`):

```sh
echo 'OPENAI_API_KEY=sk-...' > .env
swift run Coder
```

## [RealtimeVoiceAgent](RealtimeVoiceAgent/) — iOS realtime voice app

Prototype iPhone app for OpenAI Realtime voice conversations. SwiftUI, `AVAudioEngine` mic capture and playback, websocket transport, local on-device tools (calendar, reminders, notes, time, device info).

Not part of the SPM package — it's a standalone iOS app. The `.xcodeproj` is checked in for convenience but is generated from [`project.yml`](RealtimeVoiceAgent/project.yml) by [XcodeGen](https://github.com/yonaskolb/XcodeGen), which remains the source of truth.

### Build

```sh
cd Examples/RealtimeVoiceAgent
cp Config/Local.example.xcconfig Config/Local.xcconfig   # fill in your keys (see below)
open RealtimeVoiceAgent.xcodeproj
```

### Regenerating the xcodeproj

If you edit `project.yml` (adding files, changing targets, etc.), regenerate the `.xcodeproj` and commit it alongside the `.yml` change:

```sh
brew install xcodegen           # one-time
xcodegen generate
```

Avoid making structural changes directly in Xcode — they won't end up in `project.yml` and will be lost the next time someone regenerates.

### API keys

All keys live in `Config/Local.xcconfig` and get baked into `Info.plist` at build time. Edit that file (copied from `Config/Local.example.xcconfig`):

```
// One of these two is required:
OPENAI_API_KEY = sk-proj-...                     // local prototyping only
OPENAI_REALTIME_TOKEN_ENDPOINT =                 // host + path, no scheme — preferred for real deployments

// Optional — enables the Settings screen and the messageOpenClaw tool:
OPENCLAW_ENDPOINT =                              // host + path, no scheme (app prepends https://)
OPENCLAW_TOKEN =
```

Notes:

- `xcconfig` treats `//` as a comment **inside strings too**, so URLs must omit the scheme. The app prepends `https://` to `OPENCLAW_ENDPOINT` and `wss://` to `OPENAI_REALTIME_WEBSOCKET_URL` at load time.
- For a real mobile deployment, prefer `OPENAI_REALTIME_TOKEN_ENDPOINT` (your own backend that mints ephemeral tokens) over shipping an API key in the bundle.
- Other realtime settings (`OPENAI_REALTIME_MODEL`, `OPENAI_REALTIME_VOICE`, `OPENAI_REALTIME_TRANSCRIPTION_MODEL`, `OPENAI_REALTIME_USE_SERVER_VAD`, `OPENAI_REALTIME_INSTRUCTIONS`) have working defaults in `Local.example.xcconfig` — override only what you need.
- `Info.plist` references the xcconfig values via `$(...)` placeholders, so editing `Local.xcconfig` and rebuilding is enough — no need to re-run `xcodegen`.

### How it uses SwiftAgents

The app declares a local-path SPM dep on `SwiftAgents` in [`project.yml`](RealtimeVoiceAgent/project.yml) and consumes the `Providers` product. The realtime stack is wired through the package end-to-end:

- [`RVARealtimeAgent`](RealtimeVoiceAgent/App/Sources/Services/Realtime/RVARealtimeAgent.swift) conforms to `Providers.RealtimeAgent`, declares the `LocalToolRegistry` actor as its `toolProvider`, and builds the `RealtimeSessionConfiguration` (audio formats, semantic VAD, voice, transcription model) from `AppConfiguration`.
- [`LocalToolRegistry`](RealtimeVoiceAgent/App/Sources/Services/Tools/CodingAgent/LocalToolRegistry.swift) is an `@MCPServer` actor whose methods are `@MCPTool`-annotated, so it satisfies `MCPToolProviding` automatically — the package's `RealtimeSession` discovers the tools, surfaces them to the model in `session.update`, and dispatches calls back via `callTool`.
- [`OpenAIRealtimeService`](RealtimeVoiceAgent/App/Sources/Services/Realtime/OpenAIRealtimeService.swift) is now a thin adapter: it resolves auth (embedded key or ephemeral token endpoint), constructs `OpenAIRealtimeWebSocketModel` + `RealtimeSession`, and maps the package's typed `RealtimeSessionEvent` stream into the existing UI-shaped `RealtimeServiceEvent` enum the SwiftUI layer consumes.
