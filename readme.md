# SwiftAgents

A Swift-only LLM and Agents SDK, modelled after the OpenAI Agents SDK and built around the Responses API shape. Lightweight, no third-party LLM dependencies beyond what the providers themselves require, and intended to work with any LLM that can be coaxed into the Responses protocol.

## Status

Early. Split out from the private AgentCorp project so the public agent surface can stand on its own. APIs will move.

## Products

- **`Providers`** — wire-level LLM provider clients: OpenAI (Responses + Chat + Embeddings + Assistants + Conversations + Realtime + Image Generation), Anthropic Messages, Google Gemini, Ollama, and LM Studio (native stateful chat). Cross-platform.
- **`Agents`** — the agent runtime built on top of `Providers`: `Runner`, the `Agent` protocol and `BasicAgent`, handoffs, guardrails, and agent-tier Realtime. The Tool DSL is powered by [SwiftMCP](https://github.com/Cocoanetics/SwiftMCP); `applyDiff` handles V4A-style patches.
- **`SwiftAgents`** — umbrella product; `import SwiftAgents` re-exports `Providers`, `Tracing`, and `Agents`.
- **`Tracing`** — provider-agnostic tracing primitives (`TraceProvider`, `TraceSpan`, `withSpan`, …) that `Providers` and `Agents` build on.
- **`SemanticStore`** — semantic-search stores behind one `SemanticStore` protocol: the in-memory `LocalVectorStore`, the hosted `OpenAIVectorStore`, and the persistent `SQLiteVectorStore` (opt-in via the `SQLiteVectorStore` package trait). See [Docs/SemanticStore.md](Docs/SemanticStore.md).
- **`TerminalUI`** — ANSI colours, slash-command parser, terminal handler. Used by the bundled CLI; reusable by other tools.
- **`Coder`** — an in-process coding-agent CLI (executable target). Tool surface: `bash`, `read`, `write`, `edit`, `ls`, `grep`, `find`, plus `apply_patch` for models that support it. Also runs as an ACP agent: `swift run Coder acp` serves the [Agent Client Protocol](https://agentclientprotocol.com) on stdio (via [SwiftACP](https://github.com/Cocoanetics/SwiftACP)), so editors like Zed can drive it — including the client's per-session MCP servers and per-session model switching (`--model`, `/model`, or the native `session/set_model`). Reference implementation of an `Agent` against the Responses API.

## Usage

There are no tagged releases yet (see Status), so depend on `main` for now — version tags will follow once the API settles:

```swift
.package(url: "https://github.com/Cocoanetics/SwiftAgents", branch: "main")
```

Then in your target — the umbrella product re-exports `Providers`, `Tracing`, and `Agents`:

```swift
.product(name: "SwiftAgents", package: "SwiftAgents")
```

(Note that a `branch:` dependency can't ship inside your own tagged releases; treat it as development-only until SwiftAgents tags a version.)

## Quick start

Define an agent and run it:

```swift
import SwiftAgents

let agent = BasicAgent(
    name: "Assistant",
    model: "gpt-4.1",   // or "claude-sonnet-4-5", "gemini-2.5-flash", "lmstudio/qwen3-coder", …
    instructions: "You are a helpful assistant. Answer concisely."
)

let result = try await Runner.run(agent: agent, input: "What is an actor in Swift?")
print(result.finalOutput)   // BasicAgent's OutputType is String
```

Or streamed, printing text deltas as they arrive:

```swift
let streamed = Runner.runStreamed(agent: agent, input: "Explain Swift concurrency.")
for try await event in streamed.events {
    if case let .rawResponseEvent(raw) = event,
       case let .outputTextDelta(info) = raw.object {
        print(info.delta, terminator: "")
    }
}
```

See [Docs/Agents.md](Docs/Agents.md) for the full tour: structured output, tools, conversation continuity, streaming events, and `RunConfig`.

## Configuration

Tests and the bundled CLI look for these environment variables. The test suite loads them from the nearest `.env` with its own tolerant loader (`Tests/ProvidersTests/APIKey.swift`, which skips present-but-empty keys); the Coder CLI loads `.env` via [`swift-dotenv`](https://github.com/thebarndog/swift-dotenv) on Apple platforms and Linux:

| Variable | Used by |
| --- | --- |
| `OPENAI_API_KEY`    | OpenAI client + integration tests |
| `GEMINI_API_KEY`    | Google client + integration tests |
| `ANTHROPIC_API_KEY` | Anthropic client + integration tests |
| `OLLAMA_URL`        | Ollama client (defaults to `http://localhost:11434`) |
| `LMSTUDIO_URL`      | LM Studio client — local OpenAI-compatible endpoint (defaults to `http://localhost:1234`) |
| `LMSTUDIO_MODEL`    | Model pin for the LM Studio live tests (tool calls, structured output) |
| `LMSTUDIO_EMBED_MODEL` | Embedding model for the hybrid-search live tests (default `text-embedding-nomic-embed-text-v1.5`) |
| `LMSTUDIO_VISION_MODEL` | Vision model for the LM Studio image-input tests |
| `LOCAL_LLM_URL`     | Generic OpenAI-compatible local server for the embedding live tests |
| `RUN_OLLAMA_TESTS`  | Set to `1` to opt into the live Ollama chat suites (also needs a reachable `OLLAMA_URL`) |
| `LIVE_STATE_TESTS`  | Set to `1` to opt into live tests that mutate hosted OpenAI state (vector stores, conversations — also needs `OPENAI_API_KEY`) |

Local-server suites (LM Studio, Ollama, `LOCAL_LLM_URL`) additionally probe
reachability and skip when nothing is listening, so an offline `swift test`
passes with keys configured.

A `.env.example` is provided; copy it to `.env` and fill in your keys. `.env` is gitignored.

## Building

```sh
swift build
swift test                              # full suite (integration tests need keys)
swift test --filter LocalVectorStore    # offline-only
swift run Coder --help                  # the Coder CLI
swift run Coder acp                     # serve Coder over ACP on stdio
```

## Provenance

The agent runtime is a Swift port of the patterns in [openai-agents-python](https://github.com/openai/openai-agents-python). The Responses wire types are aligned with OpenAI's [public spec](https://github.com/openai/openai-openapi); other providers (Gemini, Ollama) adapt their native shapes into that contract.

## License

MIT — see [LICENSE](./LICENSE).
