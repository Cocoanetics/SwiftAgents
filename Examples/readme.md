# Examples

Reference consumers of SwiftAgents. Each subfolder is a self-contained project that shows one way to build on top of the package.

## [Coder](Coder/) — terminal coding agent

In-process coding-agent CLI. Tool surface: `bash`, `read`, `write`, `edit`, `ls`, plus `apply_patch` for models that support it. Reference implementation of an `Agent` against the Responses API.

Still wired into the root [`Package.swift`](../Package.swift) as the `Coder` executable product, so:

```sh
swift run Coder --help
```

works from the repo root. The folder lives under `Examples/` to make its role explicit — it's a real product you can install, but its primary job is to show how the `Providers` runtime is meant to be consumed.

## [RealtimeVoiceAgent](RealtimeVoiceAgent/) — iOS realtime voice app

Prototype iPhone app for OpenAI Realtime voice conversations. SwiftUI, `AVAudioEngine` mic capture and playback, websocket transport, local on-device tools (calendar, reminders, notes, time, device info).

Not part of the SPM package — it's a standalone iOS app driven by [XcodeGen](https://github.com/yonaskolb/XcodeGen).

### Build

```sh
brew install xcodegen           # one-time
cd Examples/RealtimeVoiceAgent
cp Config/Local.example.xcconfig Config/Local.xcconfig   # fill in your keys
xcodegen generate
open RealtimeVoiceAgent.xcodeproj
```

The generated `.xcodeproj` and `Config/Local.xcconfig` are gitignored. `project.yml` is the source of truth.

### Status

The app currently depends on [SwiftMCP](https://github.com/Cocoanetics/SwiftMCP) directly and reaches the Realtime API through its own `OpenAIRealtimeService`. The `App/Sources/Integrations/AgentCorp/` folder is a placeholder boundary; wiring it to the package's `Providers` realtime client is a separate follow-up.
