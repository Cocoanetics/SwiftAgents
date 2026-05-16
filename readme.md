# SwiftAgents

A Swift-only LLM and Agents SDK, modelled after the OpenAI Agents SDK and built around the Responses API shape. Lightweight, no third-party LLM dependencies beyond what the providers themselves require, and intended to work with any LLM that can be coaxed into the Responses protocol.

## Status

Early. Split out from the private AgentCorp project so the public agent surface can stand on its own. APIs will move.

## Products

- **`Providers`** — LLM provider clients (OpenAI Responses + Chat + Embeddings + Assistants + Realtime + Image Generation, Google Gemini, Ollama) plus the `Agent` / `Runner` / `Tool` runtime built on top of them. The Tool DSL is powered by [SwiftMCP](https://github.com/Cocoanetics/SwiftMCP); `applyDiff` handles V4A-style patches. The runtime will eventually split into its own `Agents` target; for now everything lives here.
- **`TerminalUI`** — ANSI colours, slash-command parser, terminal handler. Used by the bundled CLI; reusable by other tools.
- **`Coder`** — an in-process coding-agent CLI (executable target). Tool surface: `bash`, `read`, `write`, `edit`, `ls`, plus `apply_patch` for models that support it. Reference implementation of an `Agent` against the Responses API.

## Usage

```swift
.package(url: "https://github.com/Cocoanetics/SwiftAgents", from: "0.1.0")
```

Then in your target:

```swift
.product(name: "Providers", package: "SwiftAgents")
```

## Configuration

Tests and the bundled CLI look for these environment variables (typically loaded from a `.env` at the package root via [`swift-dotenv`](https://github.com/thebarndog/swift-dotenv)):

| Variable | Used by |
| --- | --- |
| `OPENAI_API_KEY` | OpenAI client + integration tests |
| `GEMINI_API_KEY` | Google client + integration tests |
| `OLLAMA_URL`     | Ollama client (defaults to `127.0.0.1:11434`) |
| `LM_STUDIO_URL`  | Optional local-OpenAI-compatible endpoint |

A `.env.example` is provided; copy it to `.env` and fill in your keys. `.env` is gitignored.

## Building

```sh
swift build
swift test                              # full suite (integration tests need keys)
swift test --filter LocalVectorStore    # offline-only
swift run Coder --help                  # the Coder CLI
```

## Provenance

The agent runtime is a Swift port of the patterns in [openai-agents-python](https://github.com/openai/openai-agents-python). The Responses wire types are aligned with OpenAI's [public spec](https://github.com/openai/openai-openapi); other providers (Gemini, Ollama) adapt their native shapes into that contract.

## License

MIT — see [LICENSE](./LICENSE).
