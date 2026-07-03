# Agents

The agent runtime: define an `Agent` (instructions plus tools, handoffs, and
guardrails), hand it to `Runner`, and get back a typed result. It is a Swift
port of the patterns in
[openai-agents-python](https://github.com/openai/openai-agents-python) —
`Runner.run` / `Runner.runStreamed` mirror `Runner.run(...)` /
`Runner.run_streamed(...)`.

Everything below is in the `Agents` module; `import SwiftAgents` (the umbrella
product) re-exports it together with `Providers` and `Tracing`.

## Quick start

```swift
import SwiftAgents

let agent = BasicAgent(
    name: "Assistant",
    instructions: "You are a helpful assistant. Answer concisely."
)

let result = try await Runner.run(agent: agent, input: "What is an actor in Swift?")
print(result.finalOutput)   // BasicAgent's OutputType is String
```

`Runner.run` executes the agent loop — model call, tool calls, repeat — until
the model produces a final answer or `maxTurns` (default 10) is exceeded. The
`RunResult` carries `finalOutput` (typed as the agent's `OutputType`),
`finalReasoning`, and the conversation handles (`lastResponseId`,
`lastConversationId`) for continuing the exchange.

## Models and providers

The model string picks the provider; the shared `ProviderRegistry` resolves it
and reads credentials from the environment:

| Model spec | Provider | Credential / endpoint |
| --- | --- | --- |
| `gpt-4.1`, `o3`, … (bare id) | OpenAI Responses | `OPENAI_API_KEY` |
| `claude-sonnet-4-5`, `anthropic/<model>` | Anthropic Messages | `ANTHROPIC_API_KEY` |
| `gemini-2.5-flash`, `gemini/<model>` | Google Gemini | `GEMINI_API_KEY` |
| `ollama/<model>`, `local/<model>` | Ollama | `OLLAMA_URL` (default `http://localhost:11434`) |
| `lmstudio/<model>` | LM Studio native chat | `LMSTUDIO_URL` (default `http://localhost:1234`) |
| `openai-websocket/<model>` | OpenAI Responses over a shared WebSocket | `OPENAI_API_KEY` |

The model comes from `RunConfig.model` if set, else the agent's `model`
property. Custom backends register with
`await ProviderRegistry.shared.register(api:forProvider:)`, or bypass routing
entirely with `RunConfig.api` (see below).

## Structured output

An agent's `OutputType` decides the output shape. `BasicAgent` is hardcoded to
`String`; for typed results, declare your own conformance with a
`@Schema`-decorated type (the macro ships in
[JSONFoundation](https://github.com/Cocoanetics/JSONFoundation), re-exported by
SwiftMCP). The runner then requests JSON-schema output and decodes
`finalOutput` for you:

```swift
import SwiftAgents
import SwiftMCP   // re-exports JSONFoundation's @Schema

@Schema
struct ColourGuess: Codable, Sendable {
    let colour: String
    let confidence: Double
}

final class ColourGuesser: Agent {
    typealias OutputType = ColourGuess
    let name = "ColourGuesser"
    let instructions = "Decide what colour a thing usually is. Answer concisely."
}

let result = try await Runner.run(agent: ColourGuesser(), input: "What colour is grass?")
print(result.finalOutput.colour)       // "green"
print(result.finalOutput.confidence)
```

Arrays of schema-representable elements also work (`typealias OutputType =
[ColourGuess]` — the runner wraps them in a `results` object on the wire).
Any other `Decodable` type is decoded from the model's plain-text answer.

## Tools

Tools use SwiftMCP's DSL: mark the agent class `@MCPServer` and each tool
method `@MCPTool` — doc comments become the tool descriptions the model sees:

```swift
import SwiftAgents
import SwiftMCP

@MCPServer
final class WeatherAgent: Agent, @unchecked Sendable {
    typealias OutputType = String
    let name = "Weather"
    let instructions = "Answer weather questions using your tools."

    /// Returns the current temperature in °C for a city.
    /// - Parameter city: Name of the city
    @MCPTool
    func temperature(city: String) async throws -> String {
        // look it up…
        return "21 °C"
    }
}
```

The runner collects tools from several places and merges them:

- the agent itself, when it is `@MCPServer`-annotated (as above),
- `toolProviders` — any `MCPToolProviding` instances,
- `tools` — explicit `Tool` values (e.g. `.applyPatch`),
- `mcpServers` — connected `MCPServerProxy` instances whose remote tools are
  exposed to the model,
- `handoffs` — each handoff appears as a `transfer_to_<agent>` tool.

Tool calls within a turn execute in parallel; results are fed back as
`function_call_output` items for the next turn. An agent can also become a tool
for another agent via `asToolProvider(toolName:toolDescription:config:)` —
that's how Coder exposes its `sub_agent`.

## Conversation continuity

Four mutually-exclusive ways to carry a conversation across runs — pass a
`session`, **or** one of the scalar mechanisms, never both (the runner throws
otherwise, since combining them would double-count items):

```swift
// 1. Session — provider-agnostic local log; works with every provider.
let session = InMemorySession()
_ = try await Runner.run(agent: agent, input: "My name is Oliver.", session: session)
let reply = try await Runner.run(agent: agent, input: "What's my name?", session: session)

// 2. previousResponseId — server-side chaining for stateful providers
//    (OpenAI Responses API, LM Studio native chat).
let first = try await Runner.run(agent: agent, input: "Hello!")
let next = try await Runner.run(
    agent: agent, input: "Continue.",
    previousResponseId: first.lastResponseId
)

// 3. autoPreviousResponseId: true — same chaining, but the resolved id rides
//    back on RunResult so you don't juggle ids by hand.

// 4. conversationId — an OpenAI Conversations API handle; the server owns
//    the history.
```

Custom `Session` conformances (the protocol lives in `Providers`) can persist
the log wherever they like; `InMemorySession` is the built-in.

## Streaming

`Runner.runStreamed` returns immediately with a `RunResultStreaming`; the agent
loop runs in a background task and pushes `AgentStreamEvent`s:

```swift
let streamed = Runner.runStreamed(agent: agent, input: "Explain Swift concurrency.")

for try await event in streamed.events {
    switch event {
        case let .rawResponseEvent(raw):
            if case let .outputTextDelta(info) = raw.object {
                print(info.delta, terminator: "")
            }
        case let .runItemEvent(name, item):
            if case .toolCalled = name, case let .toolCall(tool, args, _) = item {
                print("→ \(tool) \(args)")
            }
        case .agentUpdated:
            break
    }
}

// Valid once the stream is fully consumed:
let lastResponseId = streamed.lastResponseId
```

For OpenAI-backed models the events come from the Responses streaming API;
chat-completion-only providers (Anthropic, LM Studio, OpenAI-compatible
endpoints) are translated per-chunk into the same event shape. Cancel a run
with `streamed.cancel()`.

## RunConfig

Per-run configuration, passed as `config:` to `run`/`runStreamed`:

```swift
let config = RunConfig(
    model: "claude-sonnet-4-5",   // overrides the agent's model
    workFlowName: "Support Turn"  // names the tracing spans
)
let result = try await Runner.run(agent: agent, input: prompt, config: config)
```

- **`model`** — routed through `ProviderRegistry` as described above.
- **`api`** — inject an explicit transport, bypassing name routing. The main
  use is a per-session `OpenAIResponsesWebSocket`: sockets are sequential and
  non-multiplexed, so concurrent sessions should each own one instead of
  sharing the registry's `openai-websocket` instance.
- **`requestedMedia`** — per-run override of the output modalities to request
  (e.g. image output), replacing what the agent declares via `RequestsMedia`.
- **`workFlowName`** / **`dateDecodingStrategy`** — tracing span name and the
  date strategy for decoding provider responses (default `.iso8601`).

## Handoffs and guardrails

An agent lists `handoffs` (e.g. `BasicHandoff(targetAgent:)`); each one is
offered to the model as a `transfer_to_<agent>` tool, and the runner switches
to the target agent when called — `runStreamed` surfaces the switch as an
`.agentUpdated` event.

Guardrails hang off the agent: `inputGuardrails` are evaluated against the very
first input before the loop starts, `outputGuardrails` against the final output
before it is returned. A tripped guardrail throws
(`InputGuardrailTripwireTriggered` / `OutputGuardrailTripwireTriggered`), with
optional metadata for diagnostics.

## Tracing

Runs are traced automatically: if no trace is active, the runner opens one
named after `RunConfig.workFlowName` and the model. With `OPENAI_API_KEY` set,
an exporter auto-registers and uploads spans to OpenAI's trace viewer; wrap
several runs in one trace with `try await withTrace(name:) { … }`, or add your
own `TracingProcessor` via `TraceProvider.shared`.
