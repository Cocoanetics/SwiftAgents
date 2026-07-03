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

### ACP mode — drive Coder from any editor

`Coder` also speaks the [Agent Client Protocol](https://agentclientprotocol.com) over stdio, so any ACP client — [`acpx`](https://github.com/openclaw/acpx), Zed, or another editor — can spawn and drive it. Built on [SwiftACP](https://github.com/Cocoanetics/SwiftACP)'s server harness (pinned `traits: []` so the daemon-side transports stay out of the graph — Coder only serves stdio).

```sh
acpx run swift run Coder acp
```

The `acp` subcommand serves the protocol until the client disconnects (stdin EOF); `stdout` carries JSON-RPC only, so Coder's own diagnostics go to `stderr`. A client that spawns Coder passes the environment through, so `OPENAI_API_KEY` (or a `.env` in the working directory) is picked up the same way as the REPL.

What the ACP surface exposes:

- **Session lifecycle** — `initialize` / `session/new` / `session/prompt` with streamed `session/update`s (assistant text, reasoning, tool calls), per-turn token usage, and ACP tool-call *kinds* so clients pick sensible icons.
- **Per-session MCP servers** — the stdio MCP servers a client configures on `session/new` are spawned once per session and exposed to the agent as extra tools.
- **Slash commands + model picker** — `/new` (clear context) and `/model` are advertised via `available_commands_update`; native clients also get a model menu and `session/set_model`.
- **Session modes** (`session/set_mode`) — **`code`** (full tool access) vs. **`plan`** (read-only: `bash`, `write`, `edit`, and `apply_patch` are withheld/refused so the agent explores and proposes a plan without touching the working tree). A switch is confirmed with a `current_mode_update`.
- **Config options** (`session/set_config_option`) — a `reasoning_effort` select (`auto` / `low` / `medium` / `high`) for reasoning-capable models.
- **Resumable sessions** (`session/load`) — every session persists to `~/.coder/acp-sessions/<id>.json` (working directory, model/mode/effort, the rolling `lastResponseId`, and a short transcript). A client can reconnect to a session after the Coder process restarts: Coder restores the state, reconnects the MCP servers the client re-supplies, replays the transcript, and the next turn continues the same conversation.

`authenticate` is a no-op — Coder advertises no auth methods and reads credentials from the environment (like codex). The daemon transports (TCP / Bonjour / HTTP-SSE) are out of scope: Coder is spawn-per-client over stdio; a daemon holding live sessions is SwiftACP's job.

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
