// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
	name: "SwiftAgents",
	platforms: [
		.macOS(.v14),
		.iOS(.v17),
		.watchOS(.v10)
	],
	products: [
		// Generic tracing primitives — TraceProvider, TraceSpan,
		// TracingProcessor, withSpan, etc. Provider-agnostic so
		// `Providers` and future targets depend on it without
		// coupling to any specific LLM backend.
		.library(
			name: "Tracing",
			targets: ["Tracing"]
		),
		// LLM provider clients (OpenAI / Anthropic / Gemini / Ollama /
		// LMStudio) — wire-level only. Cross-platform.
		.library(
			name: "Providers",
			targets: ["Providers"]
		),
		// The Agent runtime (Runner, Agent / BasicAgent, Handoffs,
		// Guardrails, agent-tier Realtime) built on top of Providers.
		// Pull this in when you want the agent loop; otherwise just use
		// Providers directly.
		.library(
			name: "Agents",
			targets: ["Agents"]
		),
		// Umbrella product. `import SwiftAgents` re-exports Providers,
		// Tracing, and Agents — convenient for apps that want the whole
		// stack without listing every module.
		.library(
			name: "SwiftAgents",
			targets: ["SwiftAgents"]
		),
		// In-memory vector store, Accelerate-backed vector math, and
		// the `NLContextualEmbedding`-based local embedding provider.
		// Apple-only — each file is wrapped in `#if canImport(NaturalLanguage)`,
		// so the target compiles to nothing on Linux. Opt-in: consumers
		// that don't need local embedding can ignore this product.
		.library(
			name: "VectorStore",
			targets: ["VectorStore"]
		),
		// Reusable ANSI / slash-command helpers. Used by the Coder CLI
		// and exposed so other CLIs in the ecosystem can pick them up.
		.library(
			name: "TerminalUI",
			targets: ["TerminalUI"]
		),
		// `coder` — in-process coding-agent CLI. Reference consumer of
		// the Providers target.
		.executable(
			name: "Coder",
			targets: ["Coder"]
		)
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
		// Link only SwiftMCP's NIO-free core + the `Client` trait (the MCP
		// client we use) — NOT the `Server` HTTP transport — so swift-nio stays
		// out of SwiftAgents' graph and we build on Windows.
		.package(url: "https://github.com/Cocoanetics/SwiftMCP", from: "1.5.0", traits: ["Client"]),
		.package(url: "https://github.com/thebarndog/swift-dotenv", from: "2.1.0"),
		.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
		// Cross-platform compatibility shims (URLSession.AsyncBytes / bytes(for:),
		// UTType, …) shared via SwiftCross instead of duplicated in Providers.
		.package(url: "https://github.com/Cocoanetics/SwiftCross.git", from: "1.0.0")
	],
	targets: [
		.target(
			name: "Tracing",
			dependencies: [
				// Tracing only needs the JSONValue value type (span-data export),
				// not the MCP client or macros — link the lightweight, NIO-free
				// JSONValue product rather than the full SwiftMCP module.
				.product(name: "JSONValue", package: "SwiftMCP"),
				"SwiftCross"
			],
			path: "Sources/Tracing"
		),
		.target(
			name: "Providers",
			dependencies: [
				"SwiftMCP",
				"SwiftCross",
				"Tracing",
				.product(name: "Logging", package: "swift-log")
			],
			path: "Sources/Providers"
		),
		.target(
			name: "Agents",
			dependencies: [
				"Providers",
				"Tracing",
				"SwiftMCP"
			],
			path: "Sources/Agents"
		),
		.target(
			name: "SwiftAgents",
			dependencies: [
				"Providers",
				"Tracing",
				"Agents"
			],
			path: "Sources/SwiftAgents"
		),
		.target(
			name: "VectorStore",
			dependencies: ["Providers"],
			path: "Sources/VectorStore"
		),
		.target(
			name: "TerminalUI",
			dependencies: [],
			path: "Sources/TerminalUI"
		),
		.executableTarget(
			name: "Coder",
			dependencies: [
				"SwiftAgents",
				"TerminalUI",
				"SwiftMCP",
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
				// swift-dotenv 2.1.0 supports Apple platforms (via Darwin)
				// and Linux (via Glibc), but not Windows or Android. The
				// `#if canImport(SwiftDotenv)` guard in `Coder.swift` covers
				// those — on platforms where the dep isn't linked, the CLI
				// falls back to `ProcessInfo.processInfo.environment`.
				.product(
					name: "SwiftDotenv",
					package: "swift-dotenv",
					condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .linux])
				)
			],
			path: "Examples/Coder"
		),
		.testTarget(
			name: "ProvidersTests",
			dependencies: [
				"Providers",
				"Agents",
				"Tracing",
				"VectorStore",
				"SwiftMCP",
				"SwiftCross"
			],
			path: "Tests/ProvidersTests",
			resources: [.process("Resources")]
		)
	],
	// Tools 6.1 (needed for SwiftMCP package-trait selection) defaults to the
	// Swift 6 language mode; the package builds clean under full strict
	// concurrency.
	swiftLanguageModes: [.v6]
)
